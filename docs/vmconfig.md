<a id="429f3d06-0001"></a>

# vmconfig topic reference

This file collects the rationale behind every non-trivial line in the
per-guest `vmconfig/` artifacts (`user-data`, `meta-data`,
`autounattend.xml`). The user-data files stay short -- each topic
collapses to one line:

```
# --- REGION: https://yuruna.link/429f3d06-0003
```

The semi-GUID resolves to a `### <topic name>` heading here and stays stable
when the heading is reworded or translated.

Topics are generic (one explanation covers every guest on every host);
sub-bullets cover the exceptions a specific guest or host needs.

The **caching-proxy-service** VM has its own cloud-init seed
(`host/vmconfig/caching-proxy-service.base.user-data`), whose rationale pointers
use permanent semi-GUID targets; its per-stanza rationale is in
[Caching-proxy-service seed topics](#caching-proxy-service-seed-topics).
Everything before that section covers the shared *guest* user-data.

---

<a id="429f3d06-0002"></a>

## How user-data is rendered

Three host platforms (Hyper-V, KVM, UTM) each install Ubuntu Server or
Amazon Linux 2023 into a freshly created VM via cloud-init's NoCloud
datasource. The seed ISO they generate carries a `user-data` file
rendered per guest type from a shared base + a per-host overlay + a
per-cycle replacement table. The rendering pipeline lives in
[`automation/Yuruna.CloudInitTemplate.psm1`](../automation/Yuruna.CloudInitTemplate.psm1).

Without the pipeline, each of the six `New-VM.ps1` scripts
(3 platforms x {Ubuntu Server 24, Ubuntu Server 26}) would carry a
near-identical `vmconfig/user-data` file (~240 lines each), a
600-character `.Replace(...).Replace(...)...` chain across 11
placeholders, and a base64 dance per guest-side helper script. A fix
landing in one copy leaves the other five drifted -- the "three parallel
user-data copies" trap class in the workspace's contributor memory.

Each `host/<host>/guest.<guest>/New-VM.ps1` merges the shared
`host/vmconfig/<guest>.base.user-data` with its per-host overlay (via
`New-CloudInitUserData`) and substitutes these placeholders before
handing the result to `genisoimage` (KVM), `hdiutil makehybrid`
(macos.utm) or the cloud-init NoCloud datasource (Hyper-V):

| Placeholder | Source | Notes |
|---|---|---|
| `HOSTNAME_PLACEHOLDER` | `-Hostname` parameter, falling back to `-VMName` when empty | Becomes `identity.hostname` (autoinstall) or the hostname for AL2023 / caching-proxy-service. A sequence sets it by declaring `variables.hostname`, which the planner cascades to `New-VM`; without it the guest is named after the VM. A pinned hostname diverges from the VM name, and the UTM `dhcpd_leases` `name=` lookup keys off the name the guest registered: blocks still filed under the VM name belong to predecessors, so a VM-name-only lookup returns a dead address rather than failing outright. Discovery therefore reads the pinned name from the bundle's seed ISO, tries it first, and rejects leases not on a live host-interface subnet. |
| `INSTANCE_ID_PLACEHOLDER` | `-VMName` parameter | meta-data only. Deliberately NOT the hostname: cloud-init treats a changed instance-id as a new instance, and two VMs may legitimately share a pinned hostname. |
| `USERNAME_PLACEHOLDER` | `-Username` parameter (per-guest default; see `Test.Ssh\Get-GuestSshUser`) | Account created by autoinstall (Ubuntu Server 24.04) or by the cloud-init `users:` block (AL2023). Same name appears in `passwd --expire`, `sudoers.d/90-yuruna-<user>`, and the GUI sequences. |
| `HASH_PLACEHOLDER` | `Yuruna.Common\ConvertTo-Sha512CryptHash` (wraps `openssl passwd -6 -- <vault-password>`) | SHA-512 (`$6$`) form. Plaintext password comes from `Get-Password -Username <user>` against the persistent authentication vault (`test/status/extension/authentication/vault.yml`). KVM honors `$YURUNA_GUEST_PASSWORD` as a vault bypass for ad hoc dev runs. The `--` separator preserves passwords beginning with a dash; see "Password hashing: argv leading-dash trap" below. |
| `PLAINTEXT_PASSWORD_PLACEHOLDER` | Same as above (AL2023 path) | Used inside `chpasswd:` for AL2023, where the cloud-init module accepts the plaintext form and force-expires it on first login (chpasswd default `expire: true`). |
| `SSH_AUTHORIZED_KEY_PLACEHOLDER` | `test/status/ssh/yuruna_ed25519.pub` (auto-generated if missing) via `Test.Ssh\Get-YurunaSshPublicKey` | Single ed25519 line; placed under autoinstall.ssh.authorized-keys (Ubuntu) and the cloud-init `users:` block for the test user (AL2023). Same key the post-failure diagnostics path (`Test.Diagnostic\Invoke-RemoteDiagnosticsKeySsh`) authenticates with -- per-host key files would silently break it. |
| `APT_PROXY_BLOCK_PLACEHOLDER` | Built per-host by New-VM.ps1 | Multi-line `apt:` block. Substring-replaced (not token-aware), so the literal string MUST NOT appear anywhere else in the file. |
| `CACHING_PROXY_URL_PLACEHOLDER` | `-CachingProxyServiceUrl` parameter | Empty string when no caching-proxy-service is reachable; the `if [ -n ... ]` blocks in user-data are no-ops in that case. |
| `CA_CERT_BASE64_PLACEHOLDER` | macos.utm only -- host-fetched CA, base64-embedded | Empty when CA fetch failed; HTTPS apt then bypasses the cache. |
| `YURUNA_STATUS_SERVICE_IP_PLACEHOLDER` | Best-effort host IP discovery | Becomes `/etc/yuruna/host.env` and the `yuruna-host` `/etc/hosts` entry. |
| `YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER` | `test/test.config.yml:statusService.port` (default 8080) | Same. |
| `YURUNA_RETRY_LIB_BASE64_PLACEHOLDER` / `YURUNA_VERSIONS_BASE64_PLACEHOLDER` / `YURUNA_FAE_BASE64_PLACEHOLDER` / `YURUNA_NETWORK_BASE64_PLACEHOLDER` / `YURUNA_HOST_LOCATE_BASE64_PLACEHOLDER` | Auto-populated from `Get-YurunaGuestScriptBase64` | The five `automation/*.sh` guest helpers, embedded as base64 `write_files` entries. |
| `YURUNA_HOST_ID_PLACEHOLDER` | Auto-populated from `$env:YURUNA_RUNTIME_DIR/host.uuid` | The host identity a guest quotes when it has to find its way back to a host whose address moved. Empty when the lab has no pool directory, which is a supported outcome. A caller that already resolved the id (the service-VM seeds) passes it and wins. |
| `YURUNA_CACHING_PROXY_SERVICE_IP_PLACEHOLDER` | Auto-populated from `$env:YURUNA_CACHING_PROXY_SERVICE_IP` | Same locate path; empty when the variable is unset. |
| `YURUNA_GITHUB_REPO_PLACEHOLDER` / `YURUNA_GITHUB_REF_PLACEHOLDER` / `GH_TOKEN_PLACEHOLDER` / `YURUNA_FRAMEWORK_URL_PLACEHOLDER` / `YURUNA_PROJECT_URL_PLACEHOLDER` | Auto-populated from `Get-YurunaGitHubSource` against `-RepoRoot` | Repo slug + HEAD commit of the checkout this host is serving, the token that opens it when private, and the framework/project clone URLs a guest cut off from the host still needs. Empty fields mean "no GitHub fallback is possible"; templates that do not carry these tokens never consume them. |

Rows marked *Auto-populated* are filled in by `New-CloudInitUserData` itself,
so a `New-VM.ps1` spells them out in `-Replacement` only to override the
value the module would have resolved.

<a id="429f3d06-0003"></a>

### Three-stage rendering

| Stage | Function | Inputs | Output |
|---|---|---|---|
| 1. **Merge** | `Merge-CloudInitUserData` | shared base + per-host overlay (one of `hyperv` / `kvm` / `utm`) | Resolved template with anchors substituted, still carrying `*_PLACEHOLDER` tokens |
| 2. **Base64-encode** | `Get-YurunaGuestScriptBase64` | `<RepoRoot>/automation/{yuruna-retry.sh,yuruna-versions.sh,fetch-and-execute.sh,yuruna-network.sh,yuruna-host-locate.sh}` | `@{ RetryLib = '<base64>'; VersionsLib = '<base64>'; FetchAndExecute = '<base64>'; NetworkLib = '<base64>'; HostLocate = '<base64>' }` |
| 3. **Resolve** | `Resolve-CloudInitPlaceholder` | Merged template + replacement hashtable | Final user-data string |

`New-CloudInitUserData` is the wrapper every per-guest `New-VM.ps1`
calls -- it chains the three stages, auto-populates the guest-script
base64 entries plus the host-identity and GitHub-source entries listed
above, and optionally writes the result to `-OutputPath` (see "Output
encoding" below).

<a id="429f3d06-0004"></a>

### Placeholder safety net

`Resolve-CloudInitPlaceholder` iterates the caller's hashtable and
applies `.Replace(name, value)` for each entry. After substitution it
scans the result for any remaining `<NAME>_PLACEHOLDER` token and throws
with the offending names.

This catches typos at New-VM time -- a forgotten entry in the caller's
hashtable, or a new placeholder no caller supplies a value for -- instead
of letting a literal placeholder ship to the guest and fail
mid-autoinstall with a confusing diagnostic.

<a id="429f3d06-0005"></a>

### Files on disk

| File | Role |
|---|---|
| `host/vmconfig/ubuntu.server.base.user-data` | The shared base -- same for Ubuntu Server 24 and 26. Contains anchor lines like `# === YURUNA_OVERLAY_NETWORK ===` that the merger replaces. |
| `host/vmconfig/ubuntu.server.hyperv.overlay.yml` | Per-host overlay: `hv_balloon` denylist + `hyperv_fb` framebuffer pin. |
| `host/vmconfig/ubuntu.server.kvm.overlay.yml` | Per-host overlay: VT-blanking early-command + `consoleblank=0` + fb-safe GRUB cmdline. |
| `host/vmconfig/ubuntu.server.utm.overlay.yml` | Per-host overlay: `network:` block pinning IPv4 DHCP and refusing IPv6 RA. |
| `host/vmconfig/amazon.linux.2023.base.user-data` | The shared AL2023 base. Uses cloud-init `runcmd:` (AL2023 boots a prebuilt cloud image rather than running an Ubuntu-style autoinstall), with its own anchor set. |
| `host/vmconfig/amazon.linux.2023.hyperv.overlay.yml` | Per-host AL2023 overlay (Hyper-V). |
| `host/vmconfig/amazon.linux.2023.kvm.overlay.yml` | Per-host AL2023 overlay (KVM): `consoleblank=0` runcmd. |
| `host/vmconfig/amazon.linux.2023.utm.overlay.yml` | Per-host AL2023 overlay (UTM). |
| `automation/yuruna-retry.sh`, `automation/yuruna-versions.sh`, `automation/fetch-and-execute.sh`, `automation/yuruna-network.sh`, `automation/yuruna-host-locate.sh` | Guest-side helper scripts baked into the seed as base64 `write_files` entries. `yuruna-versions.sh` holds the pinned dependency versions and is sourced by `yuruna-retry.sh`. `yuruna-host-locate.sh` decides where the guest fetches code from, so it is seeded rather than fetched. |

<a id="429f3d06-0006"></a>

### Overlay anchor contract

Each anchor line in the base reads
`# === YURUNA_OVERLAY_<NAME> ===`. The anchor set differs by guest type
(autoinstall vs prebuilt-image `runcmd:`):

**Ubuntu Server** -- four anchors:

| Anchor | Purpose | Used by overlays |
|---|---|---|
| `NETWORK` | Per-host network: block | UTM only (Hyper-V/KVM use cloud-init defaults) |
| `EARLY_COMMANDS` | Pre-install commands | KVM only (disable VT blanking) |
| `GRUB_PRE_CONSOLE_QUIET` | Kernel quirks before `console-quiet` block | Hyper-V (`hv_balloon`+`hyperv_fb`), KVM (`consoleblank`) |
| `GRUB_POST_CONSOLE_QUIET` | Kernel quirks after `console-quiet` block | KVM only (`nomodeset` fb-safe) |

**Amazon Linux 2023** -- three anchors:

| Anchor | Purpose | Used by overlays |
|---|---|---|
| `RUNCMD_CONSOLEBLANK` | `runcmd:` block pinning `consoleblank=0` | KVM only |
| `RUNCMD_QUIET_LOGLEVEL` | `runcmd:` block for quiet/loglevel kernel-cmdline quirks | per-host as needed |
| `POWER_STATE` | `power_state:` directive (reboot/poweroff after first boot) | per-host as needed |

The overlay file uses the same anchor-line format as its section
headers; the lines
between one header and the next (or end of file) are the substitution
payload. An empty payload deletes the anchor line outright.

Anchors not represented in the overlay are a hard error -- a silent miss
would leak the literal marker into the final user-data and confuse
cloud-init.

<a id="429f3d06-0007"></a>

### Output encoding

`New-CloudInitUserData -OutputPath <file>` writes UTF-8 without a BOM and
LF line endings. cloud-init >= 22 tolerates `\r\n`, but older guests trip
on CR-sensitive shell heredocs in the rendered `late-commands` block, so
LF-only output is the durable choice.

---

<a id="429f3d06-0008"></a>

## Topic order in user-data

Late-commands (autoinstall) and runcmd (NoCloud) run sequentially. The
order below respects three real dependencies; everything else is a
convention so the three host variants of each guest stay diff-friendly:

1. `wget no_proxy` MUST precede the fetch-and-execute download and the
   timezone wget -- both go through `/etc/wgetrc`.
2. `update-grub` MUST come after every `99-yuruna-*.cfg` drop-in.
3. `umount /cdrom` + `losetup -D` MUST be the final late-commands
   (ubuntu.server.24 only -- see "Quiet post-install reboot teardown" below).

Recommended order (a guest may omit topics that don't apply):

1. Apt cache: persist proxy
2. Cap systemd-networkd-wait-online
3. Force first-login password change
4. login session budget
5. Passwordless sudo for harness user
6. Disable swap
7. Disable MOTD
8. dpkg unsafe I/O *(Hyper-V)*
9. hv_balloon denylist *(Hyper-V)*
10. hyperv_fb framebuffer pin *(Hyper-V)*
11. AL2023 framebuffer console *(amazon.linux.2023)*
12. consoleblank kernel cmdline *(KVM ubuntu.server.24)*
13. Console quiet
14. update-grub
15. Console: hold getty until cloud-init signals done *(ubuntu.server.24)*
16. Yuruna host coordinates
17. wget no_proxy
18. Install yuruna lib
19. Timezone via IP geolocation and NTP
20. Quiet post-install reboot teardown *(ubuntu.server.24)*
21. Headless host reboot on framebuffer collapse *(Hyper-V amazon.linux.2023)*

---

<a id="429f3d06-0009"></a>

## Topics

<a id="429f3d06-000a"></a>

### apt proxy block

`apt.proxy` (scoped -- not top-level `proxy:`) routes only `apt`/`apt-get`
through the local caching-proxy-service. Scope matters: top-level `proxy:` also
exports `http_proxy`/`https_proxy` into late-commands' env, which breaks
`wget https://...` against proxies that refuse CONNECT and would route
the host status-service probe through the cache.

`New-VM.ps1` injects the block at `APT_PROXY_BLOCK_PLACEHOLDER` with
`geoip: false` plus a pinned `primary` mirror; the `proxy:` line is
omitted when no caching-proxy-service is reachable. Pinning primary + disabling
geoip skips the `geoip.ubuntu.com` HTTPS lookup that otherwise adds
seconds to mirror election.

`primary:` (not curtin's `sources_list:` template): the server squashfs
ships a Deb822 `/etc/apt/sources.list.d/ubuntu.sources` already pointing
at the archive, and curtin's `modifymirrors` rewrites that URI in place,
so one `primary:` pin yields a single fully-rewritten source and apt
fetches indexes once. A `sources_list:` block instead writes a *second*
apt config beside the existing `ubuntu.sources`, doubling every per-suite
index fetch on noble; on resolute's curtin (subiquity snap 7227) it aborts
`subiquity/Mirror/cmd-apt-config` with exit 1 and drops to a recovery shell.

`String.Replace()` is substring-based, so the literal token
`APT_PROXY_BLOCK_PLACEHOLDER` must not appear in any other comment: the
multi-line YAML would splice into the wrong place and subiquity would
silently drop back to the interactive installer.

<a id="429f3d06-000b"></a>

### Why server-ISO over desktop-ISO

The cloud-init `autoinstall:` schema requires the Ubuntu **server** ISO;
the desktop ISO uses Ubiquity (or its successor), which has no
equivalent unattended-install mechanism. The test framework drives
provisioning by attaching a NoCloud seed (user-data + meta-data), and
only the server ISO's subiquity reads it. Image selection happens
in `Get-Image.ps1` per host.

<a id="429f3d06-000c"></a>

### chpasswd list schema

*(amazon.linux.2023)*

```
chpasswd:
  list: |
    ec2-user:amazonlinux
```

Stick with the (deprecated) `list:` form rather than the newer
`users:`/`type: text` schema. AL2023's cloud-init parses `list:` cleanly
in plaintext mode; under `users:`/`type: text` the `ec2-user` password
was not accepted in testing (cloud-init either never applied it or
stored it in a form `login(1)` couldn't validate), and the GUI login
sequence then loops on a wrong-password dialog. The deprecation warning
is cosmetic. Cloud-init's default `chpasswd.expire: true` applies, so
the first-login current/new/retype dialog still fires.

Do NOT add spaces after `ec2-user:` -- they become part of the password.

<a id="429f3d06-000d"></a>

### Unlocked account needs plain_text_passwd

*(service seeds: caching-proxy-service, download-agent-service,
pool-control-service, stash-service)*

`plain_text_passwd` is paired with `lock_passwd: false` and must sit in
the same `users:` entry. cloud-init checks for a password IN THAT BLOCK
when asked not to lock the account; the `chpasswd` stanza runs in a
later module and does not satisfy the check. Without it every boot
records `Not unlocking password ... no 'passwd' provided` as a
recoverable error and reports `extended_status: degraded`, which then
greets anyone reading the guest diagnostics for an unrelated fault. The
value is the same one `chpasswd` applies, so the effective credential is
unchanged.

<a id="429f3d06-000e"></a>

### ssh_authorized_keys at top level

*(amazon.linux.2023)*

Top-level `ssh_authorized_keys:` (rather than under a `users:` block)
keeps cloud-init from silently merging or dropping the key when the
username matches the distro-default user (`ec2-user`).

<a id="429f3d06-000f"></a>

### Pass-through user-data: silence SSH fingerprints

*(autoinstall, ubuntu.server.24)*

```
user-data:
  no_ssh_fingerprints: true
  ssh:
    emit_keys_to_console: false
```

Subiquity copies this block to the installed system; cloud-init consumes
it on first boot. Two knobs are flipped:

- `no_ssh_fingerprints: true` disables `cc_ssh_authkey_fingerprints`
  (the "Authorized keys for user UBUNTU" ci-info table).
- `ssh.emit_keys_to_console: false` disables `cc_keys_to_console`
  (the `BEGIN SSH HOST KEY FINGERPRINTS` / `BEGIN SSH HOST KEY KEYS`
  blocks dumped via `/dev/kmsg`, which the getty `tty1` echoes
  regardless of login state and races first-boot login).

These are distinct from `autoinstall.ssh` above (subiquity's
installer-side SSH config), which leaves `authorized-keys` / `install-server`
intact.

<a id="429f3d06-0010"></a>

### LVM sizing policy

```
storage:
  layout:
    name: lvm
    sizing-policy: all
```

`sizing-policy: all` overrides subiquity's server default (`scaled`),
which allocates only ~50% of the PV to the root LV on <50 G disks and
as little as ~12.5% on >200 G disks. Without it the node
ephemeral-storage filesystem on a 64 G qcow2 lands at ~14 GiB and trips
kubelet's eviction watermark during the website test.

<a id="429f3d06-0011"></a>

### Empty interactive-sections

*(autoinstall)*

Disables every interactive step so the install runs fully unattended.
Subiquity's unconditional "Continue with autoinstall?" confirmation
still fires; the GUI test sequence's first step uses it as a match
point.

<a id="429f3d06-0012"></a>

### Disable VT blanking on the LIVE installer kernel

*(KVM ubuntu.server.24, autoinstall early-commands)*

```
early-commands:
  - setterm --blank 0 --powersave off --cursor on > /dev/tty1 2>/dev/null || true
```

The `99-yuruna-consoleblank.cfg` GRUB drop-in covers the INSTALLED
system, but during the autoinstall phase the live-server ISO's kernel
inherits the kernel default (`consoleblank=600` = 10 min). Any quiet
phase >10 min during apt fetch / partitioning blanks the VGA
framebuffer mid-install; `virt-viewer` renders black AND
`virsh screenshot` (QMP screendump) returns black PPMs that tesseract
can't OCR -- the harness's "wait for ${vmName} login:" step then cannot
tell the install from a hang. `early-commands` run "as soon as the
installer starts, before probing for block and network devices" (Ubuntu
autoinstall reference), so this fires before any 10-min quiet window can
elapse. KVM-only concern; harmless on Hyper-V's `hyperv_fb` and Apple
Virtualization's virtio-gpu.

<a id="429f3d06-0013"></a>

### Apt cache: persist proxy

Belt-and-suspenders write of `/target/etc/apt/apt.conf.d/99yuruna-apt-cache`,
so post-install apt-get calls flow through the same caching-proxy-service subiquity
used for the install. `[ -n "$CACHING_PROXY_URL_PLACEHOLDER" ]` short-circuits when
no cache is configured, leaving the block harmless on hosts without one.

The `if`-block also opts into HTTPS caching by trusting the squid CA
and pointing `Acquire::https::Proxy` at the `:3129` ssl-bump listener:

- **Hyper-V / KVM:** the installer fetches the CA in-band via
  `wget http://${CACHE_HOST}/yuruna-squid-ca.crt` -- guests reach the
  cache VM directly on the (Default Switch / libvirt 'default') NAT.
  Failure leaves the plain-HTTP proxy in place; HTTPS apt goes direct.
- **macos.utm:** Apple VZ Shared NAT isolates guests from each other,
  so the CA fetch happens on the HOST inside `New-VM.ps1` and the bytes
  arrive base64-embedded via `CA_CERT_BASE64_PLACEHOLDER`. An empty
  placeholder is a graceful no-op: HTTPS apt bypasses the cache.

<a id="429f3d06-0014"></a>

### Enforce proxy egress

Forces ALL public HTTP/HTTPS through the cache. System-wide proxy env
vars (PAM, `/etc/profile.d`, systemd `DefaultEnvironment`) plus an
iptables REJECT on direct 80/443 to catch apps that ignore
`http_proxy` (snap, some Go binaries, browser auto-updaters). RFC1918
and link-local stay reachable so the cache, yuruna-host status service,
and LAN services keep working. Conditional on a non-empty
`CACHING_PROXY_URL_PLACEHOLDER` -- without a cache the rules are
skipped and traffic flows direct.

The three env-var sinks each serve a different reader: `/etc/environment`
for PAM (interactive, cron, ssh sessions); `/etc/profile.d` for login
shells (bash + zsh); systemd `DefaultEnvironment` for daemons started
before any user login (cron, snapd, docker, custom services). Uppercase
and lowercase variants are emitted because some tools read only one form.

`iptables-persistent` loads `/etc/iptables/rules.v4` on boot via
`netfilter-persistent.service` (Before=network-pre.target). The deb's
postinst would prompt "save current rules?"; `debconf-set-selections`
suppresses it. Public 80/443 are blocked with `REJECT
--reject-with icmp-port-unreachable` (not DROP) so the failing app
surfaces a clear error in `dmesg`/`strace`/`journalctl` instead of
hanging on a connect timeout. IPv6 is out of scope: `rules.v6` mirrors
loopback+conntrack so netfilter-persistent has a valid file to load
(otherwise it warns at boot), and default IPv6 OUTPUT stays ACCEPT.

<a id="pin-ipv4-dhcp-refuse-ipv6-ra"></a>

<a id="429f3d06-0015"></a>

### Pin IPv4-only DHCP, refuse IPv6 router advertisements

Anchor: `pin-ipv4-dhcp-refuse-ipv6-ra`

The autoinstall `network:` block in the shared
`host/vmconfig/ubuntu.server.base.user-data` pins
the primary NIC (`match: name: "en*"`) to `dhcp4: true; dhcp6: false;
accept-ra: false`. The glob (rather than a literal `enp0s1`) survives
the 26.04 guest's NIC model switch from `virtio-net-pci` (`enp0s1`)
to `e1000` (`ens1`) -- see the comment on the `Network` array in the
guest's `config.plist.template`.

Only the macOS QEMU backend needs this: on
QEMU + `-netdev vmnet-shared`, the host's VMnet stub sends IPv6
router advertisements that `systemd-networkd` interprets as interface
CHANGE events. Subiquity's `NetworkController` treats each CHANGE as
a model update, fires `_send_update`, and never proceeds past network
detection -- the install wedges with the framebuffer scrolling:

```
start:  subiquity/Network/_send_update: CHANGE enp0s1
finish: subiquity/Network/_send_update: CHANGE enp0s1
```

forever. The Apple Virtualization backend emits no such RAs, so
subiquity's auto-detection is safe there; Hyper-V and KVM guests see no
such RA stream either, so they keep auto-detection.

<a id="429f3d06-0016"></a>

### Cap systemd-networkd-wait-online

```
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=15
```

Ubuntu 24.04's `networkd-wait-online` defaults to "wait for ALL
interfaces routable, no timeout." `--any --timeout=15` means "ANY
interface routable OR 15s, whichever first" -- what the harness needs.
Cloud-init's first-boot run transitively depends on
`network-online.target`, so a stuck wait-online cascades into a
cloud-init failure or minutes of delay before login.

- **Hyper-V Default Switch:** the IPv6 path eventually resolves but
  slowly -- visible as
  `Job systemd-networkd-wait-online.service/start running ([TIME] / no limit)`.
- **Apple VZ Shared NAT (UTM):** the IPv6 RAs the tracker expects never
  arrive; without the cap the service blocks forever.
- **libvirt 'default' NAT (KVM):** can stall on IPv6 RA waits and
  delay cloud-init via `network-online.target`.

<a id="429f3d06-0017"></a>

### Password hashing: argv leading-dash trap

*(every host's `New-VM.ps1` that builds `HASH_PLACEHOLDER`)*

`ConvertTo-Sha512CryptHash` in `automation/Yuruna.Common.psm1` is the shared
helper for hashing the autoinstall / cloud-init password. It invokes:

```
& openssl passwd -6 -- $Plaintext
```

The `--` end-of-options marker is **load-bearing** and must not be
removed:

- `test/extension/authentication/default.psm1` `New-RandomPassword`
  draws from an alphabet that includes `-`
  (`a-z A-Z 0-9 !@#$%^&*()-_=+`). Roughly one in 72 generated passwords
  starts with `-`. Observed in the wild: vault produced `-4aWj*CRw`.
- Without `--`, `openssl passwd -6 -4aWj*CRw` parses `-4aWj*CRw` as an
  unknown option flag, prints `passwd: Use -help for summary` to stderr,
  writes nothing to stdout, and exits non-zero. The cycle then writes an
  EMPTY hash into the cloud-init user-data and the guest comes up with
  no working password -- recoverable only via the console.
- With `--`, the dash-prefixed token is an operand and openssl hashes
  it correctly.

The same trap applies to any caller that passes vault plaintext to a
command-line tool. Either:

- Pass plaintext AFTER `--` (e.g. `chpasswd -- "$user:$pw"`, though
  chpasswd's stdin form `echo "$user:$pw" | chpasswd` is preferable --
  it also keeps plaintext out of argv); or
- Pass plaintext via stdin (`-stdin` on openssl, the default on
  chpasswd, `SSHPASS`/`-e` on sshpass).

`chpasswd:` `list: |` blocks inside cloud-init `user-data` are NOT
affected: the literal block scalar passes the leading `-` through
intact, and cloud-init pipes the `user:password` pairs to `chpasswd` via
stdin, where argv parsing is not involved. The AL2023 guest path --
which substitutes plaintext directly into `chpasswd.list:` rather than
computing a hash -- is therefore safe by construction.

<a id="429f3d06-0018"></a>

### Force first-login password change

*(ubuntu.server.24)*

```
- curtin in-target --target=/target -- passwd --expire USERNAME_PLACEHOLDER
```

**LOAD-BEARING**: the test sequence's `Current password:` /
`New password:` / `Retype:` rotation depends on the user being
force-expired. The vault chain in
[`test/extension/authentication/default.psm1`](../test/extension/authentication/default.psm1)
assumes the OS prompts for a change on first login. `USERNAME_PLACEHOLDER`
comes from `-Username` (per-guest default, see
`Test.Ssh\Get-GuestSshUser`). This aligns with
AL2023's cloud-init default (`chpasswd.expire: true`), so the GUI test
sequence's first login fires the same Current/New/Retype dialog on every
supported host.

<a id="429f3d06-0019"></a>

### login session budget

```
sed -i -E "/^[#[:space:]]*LOGIN_TIMEOUT/d" /etc/login.defs && echo "LOGIN_TIMEOUT 180" >> /etc/login.defs
```

`/etc/login.defs LOGIN_TIMEOUT` bounds the entire authentication flow
(initial `Password:` plus Current/New/Retype on an expired account).
At the default 60s, the OCR-driven harness can run out of budget on a
busy host: each prompt costs 1 screenshot + tesseract pass + virsh
send-key chain, ~10s/step across 4 prompts plus margin. 180s gives ~3x
headroom. The `sed` strips any existing entry (commented or not) before
the append, so the change is idempotent.

The `bash -c` wrapper exists because cloud-init's YAML parser treats
the bare regex `/^[#[:space:]]*LOGIN_TIMEOUT/d` as a path; quoting it
inside `bash -c` keeps it as one shell argument.

<a id="429f3d06-001a"></a>

### Passwordless sudo for harness user

```
echo "USERNAME_PLACEHOLDER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-yuruna-USERNAME_PLACEHOLDER
chmod 440 /etc/sudoers.d/90-yuruna-USERNAME_PLACEHOLDER
chown root:root /etc/sudoers.d/90-yuruna-USERNAME_PLACEHOLDER
```

`USERNAME_PLACEHOLDER` is substituted by `New-VM.ps1` from `-Username`
(per-guest default; e.g. `yauser1` for amazon.linux.2023, `yuuser24` for
ubuntu.server.24, `yuuser26` for ubuntu.server.26, `ywuser1` for
windows.11). Ubuntu guests carry the major version in the suffix so
24.04 and 26.04 don't collide in shared logs; other guests use the
greppable `y[aw]user1` form. The harness uses this dedicated user
instead of the cloud-image defaults `ubuntu` / `ec2-user` for
greppability and to support the multi-user future declared in a
manifest.

SSH-driven workload calls `/usr/local/lib/yuruna/fetch-and-execute.sh`
without a TTY, so any sudo prompt would block. The drop-in uses the
standard `sudoers.d` form (mode 440, owner root:root) so `visudo -c`
accepts it.

<a id="429f3d06-001b"></a>

### Disable swap

```
sed -i '/ swap / s/^/#/' /target/etc/fstab
curtin in-target --target=/target -- systemctl mask swap.target
```

Test VMs run with enough RAM that paging is never desirable, and a hung
swap-target during shutdown adds seconds to every cycle. Comment the
fstab entry AND mask `swap.target` so neither the regular boot nor a
late `swapon -a` re-enables it.

<a id="429f3d06-001c"></a>

### Mask snapd seeded

```
curtin in-target --target=/target -- systemctl mask snapd.seeded.service
```

`snapd.seeded.service` runs `snap wait system seed.loaded` and is
`WantedBy=multi-user.target`, so the getty login prompt cannot appear
until snapd finishes initializing its seed -- even when zero snaps are
installed. Measured cost on a fresh ubuntu.server.24 cycle:

```
$ systemd-analyze blame | head -5
25.399s snapd.seeded.service
 1.339s cloud-config.service
 1.196s cloud-init.service
  781ms cloud-init-local.service
  663ms systemd-resolved.service

$ systemd-analyze
Startup finished in 821ms (kernel) + 29.851s (userspace) = 30.672s
```

83% of userspace boot time, gone to a snapd bootstrap that nothing
consumes. Mask only the seed-wait, NOT `snapd.service` / `snapd.socket`:
that removes the boot-time gate while keeping on-demand `snap install`
available to workload scripts via socket activation.

<a id="429f3d06-001d"></a>

### Disable MOTD

```
chmod -x /target/etc/update-motd.d/*
mkdir -p /target/etc/default && test -f /target/etc/default/motd-news && sed -i 's/^ENABLED=1/ENABLED=0/' /target/etc/default/motd-news || echo 'ENABLED=0' > /target/etc/default/motd-news
```

`update-motd.d` scripts and `motd-news` produce many lines of output on
first login (legal banners, "[N] updates can be installed immediately",
Canonical advertising). They scroll the OCR harness past the
`Password:` prompt before it can be matched, AND clutter every SSH
session's stdout. Stripping the executable bit and disabling
`motd-news` zeroes both.

<a id="429f3d06-001e"></a>

### dpkg unsafe I/O

*(Hyper-V)*

```
# /etc/dpkg/dpkg.cfg.d/99-yuruna-unsafe-io
force-unsafe-io
```

dpkg fsyncs each unpacked file before renaming it into place. On a virtual
disk every one of those becomes a flush round trip, and unpack cost then
tracks the number of files rather than their size: a 13 kB, ten-file package
can cost as much as a large one. A guest caught mid-install shows `dpkg` in
state `Ds+` blocked on `jbd2_log_wait_commit`, with the journal thread
`jbd2/dm-0-8` above `dpkg` itself in the guest's own CPU ranking. The control
is the .NET SDK, which extracts a comparable volume through a tarball with no
dpkg and no fsync and does not slow down under the same conditions.

`force-unsafe-io` drops the fsync-before-rename only. The status-database
commit and the configure phase still sync, so this shortens unpack and leaves
the rest -- it is a fix for the spread between a quiet and a contended run
rather than for the floor.

The trade is crash durability during package operations: a guest that loses
power mid-unpack can come back with a partially written file where dpkg would
otherwise have guaranteed one or the other. That is acceptable here because
these guests are reprovisioned from the installer every cycle. It is worth
knowing that a guest restored by `loadDiskSnapshot` inherits whatever its last
stop left behind, so a baseline captured from a force-stopped VM carries
slightly more risk of a missing tail than it did before.

Emitted from the Hyper-V overlay rather than the shared base, so it reaches
Hyper-V guests on both host architectures and does not reach KVM or UTM. The
architecture is deliberately not the gate: this lab runs aarch64 guests on
UTM as well, so a `uname -m` test would change durability on a host family
that gains nothing from it.

The filename carries no dot on purpose -- dpkg ignores fragments in
`dpkg.cfg.d` whose names contain one, which would disable this silently.

<a id="429f3d06-001f"></a>

### hv_balloon denylist

*(Hyper-V)*

```
# /etc/modprobe.d/denylist-hv-balloon.conf
blacklist hv_balloon
```

The synthetic balloon driver's memory-pressure notifications spam the
console and pollute OCR. The
file is inert on KVM/QEMU and macOS UTM, where `hv_balloon` never
loads -- kept for cross-host symmetry of the runcmd / write_files
shape.

<a id="429f3d06-0020"></a>

### hyperv_fb framebuffer pin

*(Hyper-V)*

```
# Ubuntu Server 24.04: /etc/default/grub.d/99-yuruna-hyperv-fb.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} video=hyperv_fb:1024x768"

# AL2023: grubby --update-kernel=ALL --args="video=hyperv_fb:1024x768"
```

When the Windows host's monitor is disconnected, `vmconnect` renders
the Linux guest as a tiny black rectangle in the top-left of an
otherwise white window: the synthetic GPU has no host-display EDID to
negotiate against in headless mode, so `hyperv_fb` falls back to a
near-zero framebuffer size. Pinning a fixed resolution makes the
in-guest driver use it regardless of host display state.

- **Ubuntu Server 24.04:** drop-in under `/etc/default/grub.d/` is additive
  -- stacks with the `consoleblank` and `console-quiet` drop-ins
  without clobbering them.
- **AL2023:** ships grub2 with no `update-grub` wrapper; `grubby`
  writes `/boot/grub2/grub.cfg` directly and is the AL2023 idiom. The
  flag list is deduplicated, so re-running with the same arg is a
  no-op. AL2023 is a prebuilt cloud image (no installer reboot), so
  the running kernel still has the OLD cmdline here -- see the
  "Headless host reboot" topic for the conditional reboot that applies
  the new arg.

<a id="429f3d06-0021"></a>

### Enable sshd on first boot

*(amazon.linux.2023)*

```
systemctl enable --now sshd || true
```

AL2023's `sshd.service` is installed but not enabled by default in the
cloud image. The harness drives the guest over SSH once the GUI test
sequence finishes its login dance, so the service must be up before
that SSH-side handoff.

<a id="429f3d06-0022"></a>

### AL2023 framebuffer console

*(amazon.linux.2023)*

```
systemctl enable --now getty@tty1.service || true
chvt 1 2>/dev/null || true
bash -c 'setterm --blank 0 --powersave off --cursor on > /dev/tty1 2>/dev/null || true'
# KVM only:
bash -c 'command -v grubby >/dev/null 2>&1 && grubby --update-kernel=ALL --args="consoleblank=0" || true'
```

AL2023 cloud images pin the kernel cmdline to `console=ttyS0` and leave
`getty@tty1.service` masked, so the VGA framebuffer captured by
`virsh screenshot` / `vmconnect` stays silent and the GUI OCR harness
never sees a `login:` prompt. The fix:

1. Enable + start `getty@tty1` so an `agetty` writes `login:` to
   `/dev/tty1`.
2. `chvt 1` forces fbcon to make `tty1` the active VT (without this
   step fbcon stays on `tty0` and getty's output is buffered but never
   painted).
3. `setterm --blank 0 --powersave off` keeps the framebuffer alive
   DURING the current cloud-init session (one-shot, per-VT escape
   sequence -- does NOT survive a getty respawn or a `chvt` away and
   back).
4. *(KVM only)* `grubby --args="consoleblank=0"` makes that no-blank
   policy authoritative at the kernel level for every subsequent boot.
   The default `consoleblank=600` (10 min) causes the "virt-viewer lost
   the VNC after a while + OCR stopped working" symptom on long test
   runs.

On an ARM64 host that `console=ttyS0` is not merely quiet: it names a
device the guest does not have, because the UART there is the SBSA PL011,
`ttyAMA0`. A serial console attached to `ttyS0` stays empty however the
boot goes, which leaves the framebuffer as the only channel unless the
cmdline is overridden --
[host-hyperv.md](host-hyperv.md#the-converted-arm64-image-does-not-boot).

UTM omits this block entirely: its display window reads the serial
console directly, with no framebuffer dependency.

<a id="429f3d06-0023"></a>

### GNOME auto-open terminal on login

*(amazon.linux.2023)*

```
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/open-terminal.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Open Terminal
Exec=ptyxis --new-window
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOP
```

AL2023's GNOME desktop boots to an empty session with no terminal
window, but the GUI OCR harness drives the guest by typing into a
terminal it can see. An XDG autostart `.desktop` entry under
`/etc/xdg/autostart/` launches `ptyxis --new-window` on every graphical
login, so a terminal is on screen by the time the harness starts its
login-and-type dance. `NoDisplay=true` keeps the launcher out of the
applications menu while still honoring the autostart, and
`X-GNOME-Autostart-enabled=true` opts it back in for GNOME.

<a id="429f3d06-0024"></a>

### consoleblank kernel cmdline

*(KVM ubuntu.server.24)*

```
# /etc/default/grub.d/99-yuruna-consoleblank.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} consoleblank=0"
```

The kernel default `consoleblank=600` (10 min) blanks the VGA
framebuffer on idle. Symptom: `virt-viewer`'s window stops updating
("looks like the VNC connection dropped"), AND `virsh screenshot` (QMP
screendump -- independent of the VNC client) starts producing black
PPMs. Both fall together because the guest's VGA framebuffer feeds
both. Pin `consoleblank=0` at the kernel cmdline so EVERY boot (and
every VT) inherits no-blank, regardless of which userspace `setterm`
calls survive.

KVM-specific: the Hyper-V variant uses `hyperv_fb:1024x768` instead, and
macos.utm's virtio-ramfb does not blank the same way.

<a id="429f3d06-0025"></a>

### Console quiet

```
# Ubuntu Server 24.04: /etc/default/grub.d/99-yuruna-console-quiet.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no"

# AL2023: grubby --args="quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no"
```

`passwd`'s `Current password:` prompt parks the cursor at end-of-line
with no trailing newline. On first boot, late-finishing units (snapd
seed, `cloud-final`, etc.) and `KERN_INFO`/`NOTICE` printk messages
keep writing `[ OK ] ...` lines to `/dev/console`, overwriting the parked
prompt before the OCR snapshot fires; the harness then sees the status
line and never matches `Current password:`.

- `quiet loglevel=3` raises the printk console threshold from the
  default 4 (`KERN_WARNING`) to 3 (`KERN_ERR`), suppressing routine boot
  chatter; errors still surface.
- `systemd.show_status=no rd.systemd.show_status=no` mute systemd's
  `[ OK ] Started ...` / `[FAILED]` banners in both the initrd and the
  main system.
- `quiet` is usually already in the default cmdline -- both
  `update-grub` and `grubby` deduplicate, so the repeat is a no-op.

<a id="console-fb-safe"></a>

<a id="429f3d06-0026"></a>

### Console: bochs-DRM framebuffer safety (KVM)

Anchor: `console-fb-safe`

```
# host/vmconfig/ubuntu.server.kvm.overlay.yml (YURUNA_OVERLAY_GRUB_POST_CONSOLE_QUIET)
- |
  cat > /target/etc/default/grub.d/99-yuruna-fb-safe.cfg << 'GRUBCFG'
  GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} nomodeset console=tty0 console=ttyS0,115200"
  GRUBCFG
```

The KVM bochs-DRM trap class (captured in
`feedback_kvm_bochs_drm_resolute_install_trap.md`) lands a kernel oops in
`ovl_iterate_merged` plus `drm_fb_helper_damage_work` CPU thrash on the
resolute live-server installer when the q35+UEFI default video drives
subiquity. The install-phase kernel cannot be reached from outside
(virt-install `--extra-args` needs `--location`, not `--cdrom`), but
pinning `nomodeset` on the *installed* kernel keeps the same trap from
biting on the subsequent boots the harness drives. `nomodeset` disables
KMS so no DRM driver loads at all; the serial console gives a diagnostic
channel that doesn't depend on the framebuffer.

<a id="429f3d06-0027"></a>

### update-grub

```
- curtin in-target --target=/target -- update-grub
```

Regenerates `/boot/grub/grub.cfg` so the GRUB drop-ins above
(`99-yuruna-hyperv-fb.cfg`, `99-yuruna-consoleblank.cfg`,
`99-yuruna-console-quiet.cfg`, `99-yuruna-fb-safe.cfg`) take effect on
the post-install reboot, and must come AFTER all of them. AL2023 ships
no `update-grub` wrapper; `grubby` does the same job inline and is
called per-arg above.

<a id="429f3d06-0028"></a>

### Console: hold getty until cloud-init signals done

*(ubuntu.server.24)*

```
# /etc/systemd/system/getty@.service.d/override.conf
[Service]
ExecStartPre=-/usr/bin/cloud-init status --wait
```

cloud-init's `running 'modules: final'` / `finished` lifecycle banners
reach the console via `/dev/kmsg` (kernel-style
`[ 44.688245] cloud-init[1065]:` timestamps) unconditionally -- unlike
the `cc_keys_to_console`/`cc_ssh_authkey_fingerprints` pair, no
cloud-config knob silences them. On first boot those banners land AFTER
getty has drawn `login:`, so the typed username and `login(1)`'s
subsequent `Password:` prompt get split across the cloud-init dump and
OCR cannot match `Password:`.

`cloud-init status --wait` is the contract cloud-init exposes for
"wait until I'm done"; the leading `-` keeps a degenerate cloud-init
from blocking getty forever. The drop-in lives on the template
(`getty@.service.d/`) so it covers `tty1` and any other getty
`systemd-getty-generator` spawns.

`[Unit] After=cloud-final.service` is not enough: it is ordering only
(no `Wants`/`Requires`) and loses a ~5% race on fast boots. When
`getty.target` is reached BEFORE `cloud-final.service` enters the
systemd transaction, the queued `getty@tty1` job is silently dropped and
the VM hangs at "Finished cloud-final.service" with no login prompt
forever (cloud-init issue #2158, lp #1804957). `status --wait` in
`ExecStartPre` avoids the race.

<a id="429f3d06-0029"></a>

### Yuruna host coordinates

```
mkdir -p /etc/yuruna
cat > /etc/yuruna/host.env <<EOF
YURUNA_STATUS_SERVICE_IP=YURUNA_STATUS_SERVICE_IP_PLACEHOLDER
YURUNA_STATUS_SERVICE_PORT=YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER
EOF
grep -q yuruna-host /etc/hosts || echo "YURUNA_STATUS_SERVICE_IP_PLACEHOLDER yuruna-host" >> /etc/hosts
```

Two artifacts written for the dev iteration loop:

- `/etc/yuruna/host.env` -- guest scripts source this to prefer the
  local status service over GitHub. `Test-YurunaHost.ps1` is the
  in-guest probe that verifies these coordinates are still valid.
- `/etc/hosts` `yuruna-host` entry -- a stable name that survives DHCP
  renumbering inside the guest's session.

- **Hyper-V Default Switch:** the host IP changes across host reboots.
  Rebuild the guest if `Test-YurunaHost.ps1` fails after a host reboot.
- **libvirt 'default' (KVM):** the gateway is stable at
  `192.168.122.1` -- no rebuild needed.

<a id="429f3d06-002a"></a>

### Host address refresh timer

```
[Unit]
After=network.target NetworkManager-wait-online.service systemd-networkd-wait-online.service
Before=network-online.target
[Service]
Type=oneshot
TimeoutStartSec=30
ExecStart=/usr/local/lib/yuruna/yuruna-host-locate.sh
[Install]
WantedBy=network-online.target
---
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
```

The host coordinates in `/etc/yuruna/host.env` are baked at `New-VM` time and
nothing in the guest re-resolves them. `fetch-and-execute.sh` repairs the
address at the top of each step, which leaves one window open: a step that
runs for many minutes can watch the host renumber underneath it and has no
way back. The timer closes that window for everything that never passes
through the fetch path at all -- the project's own scripts, the perf
checkpoints, the log uploads -- all of which read the same `host.env`.

The service VMs (`pool-control-service`, `download-agent-service`,
`stash-service`, `caching-proxy-service`) need it hardest: they are
provisioned once and then run for weeks, so they accumulate renumbers a test
guest rebuilt every cycle never sees, and nobody is typing into them.

Affordable at a one-minute cadence because `yuruna-host-locate` probes the
coordinate the guest already holds before it consults the pool directory:
while the address is still good the tick costs one LAN round trip and no
writes. A `oneshot` rather than a daemon -- no state carries between ticks,
and a oneshot cannot wedge. `TimeoutStartSec=30` is the backstop for the day
one of the resolver's own wall-clock caps stops holding, so a resolver that
cannot finish never holds the boot open.

The unit is ordered *into* the `network-online.target` barrier rather than
after it. Anything in the guest that needs the host waits on that target, so
finishing before it is what guarantees those consumers never read a stale
address -- without this unit naming a single one of them, which is the whole
point of the indirection. The `After=` line lists both wait-online
implementations because ordering against an absent unit is a no-op, so one
line covers whichever the image ships and still runs with an address in hand
rather than before DHCP has answered.

Source: [`automation/yuruna-host-locate.sh`](../automation/yuruna-host-locate.sh),
[`host/vmconfig/pool-control-service.base.user-data`](../host/vmconfig/pool-control-service.base.user-data).

<a id="429f3d06-002b"></a>

### wget no_proxy

```
cat >> /etc/wgetrc <<EOF
no_proxy = YURUNA_STATUS_SERVICE_IP_PLACEHOLDER
EOF
```

Belt-and-suspenders for the host status-service probe. subiquity's
`apt:proxy` (or AL2023's environment) can leak as `http_proxy` into the
installed system. Without `no_proxy`, an in-guest `fetch-and-execute.sh`
that lacks `--no-proxy` routes the `/livecheck` probe through the
caching-proxy-service, which cannot reach the host's NAT address
(Hyper-V Default Switch / libvirt default / Apple VZ Shared NAT), and
silently falls through to GitHub.

MUST come BEFORE the fetch-and-execute download and the timezone wget
(both rely on the same `/etc/wgetrc`).

<a id="429f3d06-002c"></a>

### Install yuruna lib

```
write_files:
  - path: /usr/local/lib/yuruna/yuruna-retry.sh
    encoding: base64
    content: YURUNA_RETRY_LIB_BASE64_PLACEHOLDER
    permissions: '0644'
  - path: /usr/local/lib/yuruna/fetch-and-execute.sh
    encoding: base64
    content: YURUNA_FAE_BASE64_PLACEHOLDER
    permissions: '0755'
```

(or, in Ubuntu autoinstall `late-commands:`, the same body written via
`printf '%s' "PLACEHOLDER" | base64 -d > /target/usr/local/lib/yuruna/...`.)

All five `automation/*.sh` helpers land in the canonical
`/usr/local/lib/yuruna/` directory on every supported guest:

- `yuruna-retry.sh` -- sourced by every guest provisioning script for
  `apt_retry` / `dnf_retry` / `curl_retry`. See
  [Defining yuruna retry lib](https://yuruna.link/4220a755-0003).
- `yuruna-versions.sh` -- the pinned dependency versions, sourced in turn
  by `yuruna-retry.sh`.
- `fetch-and-execute.sh` -- the harness's invocation point; the
  test-sequence YAMLs call it as
  `/usr/local/lib/yuruna/fetch-and-execute.sh <relative/path/script.sh>`.
- `yuruna-network.sh` -- guest network diagnostics and DHCP lease
  release.
- `yuruna-host-locate.sh` -- re-resolves the host's status-service
  address. Seeded rather than fetched because it is what decides where
  the guest fetches code from.

They are read at seed-build time by the host-side `New-VM.ps1`,
base64-encoded, and embedded as cloud-init `write_files:` content, so
they are on disk before any provisioning script runs. Single source of
truth: `automation/` in the framework repo.

<a id="429f3d06-002d"></a>

### Timezone via IP geolocation and NTP

```
timedatectl set-ntp true
TZ=$(wget -qO - --timeout=5 "http://ip-api.com/line?fields=timezone")
[ -n "$TZ" ] && timedatectl set-timezone "$TZ"
```

Best-effort: on failure (no `wget`/`curl`, no network, API down) it
prints a `Yuruna => Timezone sync failed` warning to stderr and proceeds
with UTC.

- **ubuntu.server.24:** wget-based.
- **amazon.linux.2023:** curl-based (AL2023 ships curl by default but not
  wget on the cloud image).

<a id="429f3d06-002e"></a>

### Quiet post-install reboot teardown

*(ubuntu.server.24)*

```
- umount -lf /cdrom || true
- losetup -D || true
```

subiquity holds `/cdrom` (autoinstall ISO) and snapd holds the squashfs
loops; `systemd-shutdown` can't detach them in time and logs cosmetic
`[FAILED] Failed unmounting cdrom` + `Could not detach loopback
/dev/loopN` messages on the install->reboot edge. Running these from
the installer (last late-command, against `/cdrom` NOT
`/target/cdrom`) drops the references before reboot.

`-lf` = lazy-force; both carry `|| true` because either may already be a
no-op, and a non-zero exit here would fail the entire install.

MUST be the final two late-commands.

<a id="429f3d06-002f"></a>

### error-commands installer log upload

*(ubuntu.server.24, ubuntu.server.26)*

```
error-commands:
  - <PUT subiquity / curtin / cloud-init logs to the host status service>
```

Runs in the live-installer environment when subiquity aborts the
install. POSTs the curtin / cloud-init / crash files to the host status
service's `/log-upload/` endpoint so the underlying failure (`apt-get`
exit 100, mirror 5xx, hash-sum mismatch) shows in the dashboard instead
of being lost when the installer drops to a shell.

- `--no-proxy` / `--noproxy '*'`: bypass any apt proxy that may
  itself be the failure.
- Per-file failures are swallowed (`|| true`) so one bad upload does not
  mask the next.
- `HOST_IP` / `HOST_PORT` baked from `YURUNA_STATUS_SERVICE_IP_PLACEHOLDER` /
  `YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER`; if either is empty the block
  early-exits 0 (nothing to upload to).

Bucket layout on the status service:
`installer-fail/<hostname>/<UTC-timestamp>/<file>`.

Capture the network snapshot before attempting any file upload. The ordinary
installer logs can be absent, while route state still distinguishes a guest
that lost its default route from an available route whose remote endpoint
refused or timed out. Upload `curtin-errors.tar` as well: curtin can preserve
its useful logs only inside that archive when the separately named files were
never written.

<a id="429f3d06-0030"></a>

### Headless host reboot on framebuffer collapse

*(Hyper-V amazon.linux.2023)*

```
power_state:
  delay: now
  mode: reboot
  message: "Yuruna: rebooting to apply video=hyperv_fb:1024x768 cmdline (headless host)."
  condition: ["/bin/sh", "-c", "test -f /run/yuruna-needs-reboot"]
```

AL2023 is a prebuilt cloud image (no installer reboot), so after the
`grubby --args="video=hyperv_fb:1024x768"` step the running kernel still
has the OLD cmdline: the first boot's framebuffer stays a tiny black
rectangle and the OCR-driven test sequence sees nothing.

A runcmd probe earlier in the file checks
`/sys/class/graphics/fb0/virtual_size` and only `touch`es
`/run/yuruna-needs-reboot` when the width is `< 800`, so a host with a
monitor attached (already rendering correctly) skips the reboot and the
test sequence's first `login:` capture proceeds on the first boot.

cloud-init's per-instance lifecycle keeps this from re-firing on later
boots even if the sentinel file were recreated: `cc_power_state_change`
is marked done for the instance after its first successful run.

<a id="429f3d06-0031"></a>

### Universe packages go in late-commands, not `packages:`

A package that lives in `universe` rather than `main` is installed from the
autoinstall `late-commands` section, through
`curtin in-target --target=/target -- apt-get install`, and never by adding its
name to the `packages:` list. The overlay slot for such a package is left
deliberately empty with a comment saying so, which is why an empty anchor there
is not an oversight.

**A `packages:` retrieval failure is fatal.** curtin reports
`system-install --download-only` exit 100, subiquity aborts, and the guest never
reaches a login prompt -- the whole build is lost over a package that is usually
an optimization (`qemu-guest-agent` improves address discovery; the guest still
provisions without it). A late-command that fails is tolerated with `|| true`,
so the build completes and the capability degrades instead.

**The two routes do not even resolve the same sources.** `packages:` is
processed by the installer environment, with whatever it has enabled at that
moment; `curtin in-target` resolves against the TARGET system's sources, which
carry `universe`. That difference is not theoretical: `iptables-persistent` is
also a universe package and installs through the in-target route on hosts where
the same name in `packages:` does not resolve at all.

The corollary for the enabling step: a late-command that only enables a unit
(`systemctl enable qemu-guest-agent.service`) tolerates failure for the same
reason, because an aborted late-command phase fails the entire install while a
missing optional agent only sends discovery down to its next rung.

---

<a id="429f3d06-0032"></a>

## Caching-proxy-service seed topics

This section collects the rationale behind every non-trivial cloud-init stanza
in
[`host/vmconfig/caching-proxy-service.base.user-data`](../host/vmconfig/caching-proxy-service.base.user-data) --
the seed that builds the Yuruna **caching-proxy-service** VM (squid SSL-bump cache +
zot OCI pull-through registry + the Prometheus / Grafana / Loki observability
stack + the pool-aggregator-service collector). The user-data file stays lean:
each topic collapses to a one-line pointer such as:

```
# See https://yuruna.link/429f3d06-0033
```

The semi-GUID resolves to the corresponding `### <topic name>` heading in this
section without depending on its English heading text.

The docs cover the cache from three angles:

- The guest [Topics](#topics) above -- shared guest user-data rationale; the
  cache appears there only as a *client* concern (apt proxy block, CA trust,
  proxy egress enforcement).
- [caching.md -> operator reference](caching.md#caching-proxy-service--test-harness-operator-reference) -- the operator / wiring
  (serving remote clients, port-map dispatch, host-proxy promotion): *using*
  the cache, where this section is about how the cache VM is *built*.
- [caching.md](caching.md) -- squid SSL-bump, refresh_pattern and
  YurunaCacheContent concepts referenced from the embedded squid.conf.

Comments that live *inside* the deployed artifacts (the squid.conf directives,
the embedded Python rewriter, the runcmd shell scripts, the systemd units) stay
with their file -- they ship to the guest and are read in place when debugging
the running VM. This section covers the cloud-init-level structural rationale.

Topics follow the top-to-bottom flow of the user-data (cloud-config keys, then
`write_files`, then `runcmd`), so the file and this section read side by side.

<a id="429f3d06-0033"></a>

### Squid-cache hostname vs template name

```
hostname: yuruna-caching-proxy-service
```

The OS-side hostname stays in lock-step with the hypervisor's VM / libvirt
domain name (`yuruna-caching-proxy-service`). Renaming happens HERE only -- the
source-tree directory `guest.caching-proxy-service/` and the image filename keep the
`caching-proxy-service` token because they identify the guest type /
template, not the running VM. The split prevents a rename cascade across the
repo when the runtime VM is renamed.

<a id="429f3d06-0034"></a>

### Users replace cloud image default with a per VM admin account

Replace the Ubuntu cloud image's default `ubuntu` user with `caching-proxy-service-admin`. A `users:` block WITHOUT `- default` suppresses ubuntu creation entirely -- only the listed users land in /etc/passwd. Each VM family gets its OWN administrator name (`caching-proxy-service-admin`, `download-agent-service-admin`, `pool-control-service-admin`, `stash-admin`) so their vault entries stay independent: under a shared name the vault holds one password and the most recently built VM invalidates the console credential of the others. `caching-proxy-service-admin` gets:
- Passwordless sudo (this VM is a debug box on a private network).
- The yuruna harness SSH key for passwordless `ssh caching-proxy-service-admin@<cache-ip>`.
- lock_passwd: false so chpasswd below can set a known random password for console fallback (the host VM console) while cloud-init is unfinished and SSH is not up yet.

<a id="429f3d06-0035"></a>

### Grafana apt repo inline GPG key

Grafana OSS repo: inline ASCII-armored key (keyserver.ubuntu.com is intermittently unreliable; an inline key avoids cascade failures during package-update). Rotate by refetching from https://apt.grafana.com/gpg.key when Grafana publishes a new key (verify fingerprint B53A E77B ADB6 30A6 8304 6005 963F A277 1045 8545).

<a id="429f3d06-0036"></a>

### Package squid-openssl not squid

squid-openssl: OpenSSL-linked build. Ubuntu's default `squid` package is built WITHOUT --with-openssl (Debian packaging split over OpenSSL vs GPL licensing), so its http_port parser rejects `ssl-bump`, `tls-cert=`, etc. with a "Bungled" FATAL at config-load and squid.service never binds a socket. squid-openssl ships the same /usr/sbin/squid and squid.service unit, and Conflicts: squid.

<a id="429f3d06-0037"></a>

### squidclient and apache2

squidclient (/usr/bin/squidclient) ships in squid-common (already pulled in by squid-openssl); no separate package needed. PURGE example: curl -x http://<cache>:3128 -X PURGE http://<origin>:<port>/<path>

`squid-cgi` (the cachemgr.cgi web UI) is deliberately NOT in the package list, and there is no `yuruna-cachemgr.conf` apache drop-in. Ubuntu dropped the package in 26.04 (Squid 7), so requesting it finds no installation candidate and FAILS the entire cloud-init package transaction. Reach cache-manager data with `squidclient mgr:<page>` on the VM instead; `cachemgr_passwd` stays set in squid.conf.

<a id="429f3d06-0038"></a>

### Monitoring stack packages

Monitoring stack: Prometheus scrapes squid-exporter (localhost:9301); Grafana on :3000 (anonymous Viewer). squid-exporter has no apt package and no stable GitHub release-asset URL, so golang-go is pulled in just long enough to `go install` it; both build tools are purged at the end of runcmd (~400 MB reclaimed). The compiled binary stays.

loki + promtail back the "Recent 100 requests" Grafana panel -- Prometheus stores only aggregates, so per-request client IP / target URL are not available there. Promtail tails /var/log/squid/yuruna_access.log (squid's custom `logformat yuruna` stream) and ships to Loki on localhost:3100. Both come from apt.grafana.com (same repo as grafana) -- no extra source needed.

<a id="429f3d06-0039"></a>

### Package acl for promtail log read

acl: needed by the post-zot setfacl step that grants promtail read access on /var/log/zot/zot.log (zot writes mode 0600, so group-read alone isn't enough -- promtail can't tail it without an ACL).

<a id="429f3d06-003a"></a>

### Network debugging tool packages

Network debugging tools for interactive triage via console/SSH. The server cloud image ships `ip` but not `ifconfig` or `ping`; cheap to install, big quality-of-life win.

<a id="429f3d06-003b"></a>

### Package openssl for CA generation

openssl for the CA-generation step in runcmd. The cloud image ships libssl but not the /usr/bin/openssl CLI, so `req -x509` would fail with "command not found" and leave squid's http_port 3129 unable to load tls-cert/tls-key. Kept top-level (not apt-get in runcmd) so failure surfaces in the package-install phase, not halfway through cache setup.

<a id="429f3d06-003c"></a>

### Package unattended-upgrades

unattended-upgrades: applies security + LTS-point patches daily via the stock apt-daily.timer + apt-daily-upgrade.timer units that the package's postinst enables. With the 20auto-upgrades drop-in below it gives the long-lived cache VM a self-maintained patch cadence, so it does not accumulate CVEs between cache rebuilds. A first-boot `apt-get -y upgrade` at the end of runcmd clears the backlog between the cloud image's build date and now.

<a id="429f3d06-003d"></a>

### Packages cifs-utils and sqlite3 for NAS replication

cifs-utils + sqlite3 back the optional networkStorage pool (ypool-nas) service replication: the ypool-nas-replicate.timer mounts the NAS share over SMB3 (cifs) and uses sqlite3's online .backup to copy Grafana's live grafana.db consistently. Both are tiny Ubuntu-main packages with no kernel-version dependency, so they stay top-level (failure surfaces in the package phase, not mid-runcmd); the timer is only enabled when the seed was built with replication configured.

<a id="429f3d06-003e"></a>

### Apt retries on transient errors

Retry apt fetches on transient network errors. Cloud-init's default is one-shot; a single timeout or TCP reset against archive.ubuntu.com fails the whole package install and leaves the VM without squid -- the "Exit code: 100 / Stdout: -" failure seen against `apt-get install apache2 squid`. Retries=5 covers transient hiccups but does NOT paper over 4xx (429/404) -- apt treats those as fatal and they need operator attention via /var/log/cloud-init-output.log.

<a id="429f3d06-003f"></a>

### Unattended-upgrades schedule

unattended-upgrades enable flags. Both timers (apt-daily.timer + apt-daily-upgrade.timer) ship with the apt package and are enabled by default -- this drop-in turns the upgrade phase on. Update-Package-Lists = run `apt-get update` daily; Unattended-Upgrade = run the upgrade phase daily. Auto-clean keeps /var/cache/apt bounded between cycles. The default /etc/apt/apt.conf.d/50unattended-upgrades scopes upgrades to the security pocket only -- leave that conservative; widening to all pockets risks pulling in a kernel that needs a reboot we can't schedule on a long-lived cache box.

<a id="429f3d06-0040"></a>

### Pool intent store over read-only HTTP

Pool intent store: serve the bare git repo READ-ONLY over the LAN via apache's static (dumb-HTTP) git protocol. Pooled hosts clone/pull http://<proxy>/pool-intent.git to learn pool membership + desiredState. The repo holds only NON-SECRET intent (pools.yml / test-sets / guests.compatibility); writes go through the admin CLI on the proxy (a local/file:// path), never this HTTP route. RFC1918 only, mirroring the cachemgr access policy.

The `Alias` points at the pool NAS, not a proxy-local copy: the pool-control-service daemon runs on its own VM and can only PUSH to a location it mounts, and this share is the one both it and this proxy mount read-write. Pointing apache at the same bytes keeps one store, so an operator writing intent in the UI and a runner pulling it cannot diverge. The route 404s while the NAS is unmounted, which is the honest answer; a stale local copy would hide the outage from every runner.

<a id="429f3d06-0041"></a>

### Squid drop-in config approach

Drop-in overrides on top of Ubuntu's stock /etc/squid/squid.conf. conf.d files include after the main config so same-named directives here win. A drop-in (rather than a full replacement) means future squid package upgrades keep their default refresh_pattern and ACL baseline -- only the yuruna-specific bits are overridden.

Squid is a generic HTTP proxy/cache for test-VM installs. It replaced apt-cacher-ng, which cached only `.deb` URLs and still let security.ubuntu.com 429s bubble up to subiquity (its pre-install kernel fetch went direct). Squid caches any cacheable HTTP response, so the installer's own `apt-get --download-only` of linux-firmware etc. hits cache on subsequent installs.

Do NOT declare `http_port 3128` in the drop-in. Ubuntu's stock /etc/squid/squid.conf already declares it, and /etc/squid/conf.d/* is INCLUDED (not overlaid) -- a duplicate makes squid bind twice, the second failing with EADDRINUSE (`listen ... (98) Address already in use`) while squid still appears 'running'. The default binding (all interfaces, :3128) is what we want.

<a id="429f3d06-0042"></a>

### Snapshot cache tuning

The `/etc/squid/conf.d/yuruna.conf` drop-in tunes squid as a **replayable
snapshot** rather than a churn-optimized web cache:

1. objects stay until the disk is nearly full (no proactive release);
2. the cache keeps serving when origin is unreachable or sends
   cache-hostile headers;
3. with `offline_mode` (flipped by runcmd after prewarm), a full cache
   supports guest installs with zero internet.

**Replacement policies.** `cache_replacement_policy heap LFUDA` keeps
frequently-used large objects (linux-firmware, kernels) over many small
ones; `memory_replacement_policy heap GDSF` does the same in-memory. When
eviction fires, rarely-touched small objects drop first -- the big,
expensive-to-refetch blobs survive, which offline replay needs.
The ordering constraint is load-bearing (and stays inline beside the
directive): `cache_replacement_policy` MUST appear before `cache_dir`,
because squid binds the policy at `cache_dir` parse time and a later
override has no effect.

**cache_mem budget math.** `SQUID_CACHE_MEM_PLACEHOLDER` is resolved with
the VM memory profile: 3 GB of Squid cache in an 8 GB default VM, or 7 GB in
a 12 GB lab beacon, with 4 vCPU in either profile. RAM and Squid cache size
must move together because swap is masked. The headroom calculation is in
[caching.md -> Cache VM sizing](caching.md#cache-vm-sizing).

**Disk cache sizing.** `cache_dir ufs /var/spool/squid 393216 16 256`:
384 GB of the 512 GB VM disk for squid (393216 MB in squid's three-int
size/L1-dirs/L2-dirs format), leaving ~128 GB for OS, logs, and headroom.
`ufs` is fine for a single-host dev cache; switch to `aufs`/`diskd` only
if squid blocks on disk I/O under concurrent installs.

**Object-size ceiling.** `maximum_object_size 65 GB` covers every
install image yuruna provisions, including the macOS install image
(~18 GB) and headroom for a 64 GB worst case (Xcode-bundled SDKs, full
Windows Server install media, full-fat dev VM templates). Squid's
threshold is INCLUSIVE -- anything strictly larger is silently NOT
cached -- so the 1 GB headroom on top of 64 GB matters. Raising the
ceiling allocates no disk; it only moves the rejection threshold.

**Objects until near-full.** `cache_swap_high 99` / `cache_swap_low 98`:
never release unless forced -- evict only when the disk is more than 99%
full, stopping at 98%. The squid defaults (90/95) would start evicting
with ~5 GB still free, which is wrong for a sticky snapshot cache.

**offline_mode replay.** `offline_mode on` serves cached objects without
ever revalidating them with origin. Aggressive on purpose -- this VM
exists to keep test cycles running when upstream registries (Docker Hub,
registry.k8s.io, registry.opentofu.org, public.ecr.aws, etc.) have
intermittent 5xx / rate-limit incidents. With `offline_mode` off (the
squid default), the catch-all `refresh_pattern .` revalidates every hit,
so a single upstream 5xx tears down the cycle even when squid has
everything else cached. With `offline_mode` on, cache MISSes still fall
through to upstream (otherwise the VM could never warm up); only HITs are
served unconditionally. "Flip squid into offline mode" below covers the
post-prewarm runcmd flip.

**Container-registry digest caching (OCI + Docker v2).** Diagnostics
against active cycles showed identical digest-pinned blob/manifest URLs
being re-fetched multiple times per cycle (per
`awk '$4 ~ /MISS/' /var/log/squid/yuruna_access.log`):
`/v2/.../manifests/sha256:<hex>` and `/v2/.../blobs/sha256:<hex>` are
immutable by definition, yet registries return
`Cache-Control: must-revalidate` (or `private`) on them, so the stock
catch-all `refresh_pattern .` revalidates on every request. The override
targets digest-pinned URLs only (the `sha256:` segment); those cache for
the full year like apt `.deb` files. Tag-based manifest URLs
(`/manifests/<tag>` with no `sha256:`) stay revalidated -- tags ARE
mutable, e.g. `:latest`, `:2`, `:v0.28.4`. They get only a short
freshness window (`5 50% 60`) so concurrent guests in the same cycle hit
cache while a tag move within a few minutes is still picked up;
`collapsed_forwarding` already pools the parallel fetches, so the window
just stretches past `must-revalidate`. The digest pattern matches the URL
PATH, so it works for any registry host: registry.k8s.io, ghcr.io,
registry-1.docker.io, public.ecr.aws, us-east4-docker.pkg.dev, and the
CDNs they 307-redirect to (cloudfront, S3, R2 cloudflarestorage) -- all
of which carry the `sha256:` segment in the redirected path.

Versioned package URLs use a one-year freshness window (525600 minutes). A new version has a new URL; the refresh overrides prevent origin or intermediate cache-control hints from forcing redundant revalidation of the existing object.

<a id="429f3d06-0043"></a>

### Upstream stall and fetch pooling guards

Four directives that together keep one bad origin from taking a whole
cycle down. Tuned as a group -- changing one in isolation usually
moves the stall elsewhere.

**`quick_abort_min -1 KB`** disables the quick-abort threshold entirely,
so a client that disconnects mid-fetch (a guest rebooting, say) does not
cancel the transfer. Squid finishes the object and the next client gets a
hit instead of restarting the download.

**`read_timeout 2 minutes`** bounds upstream inactivity. Squid's default
is 15 minutes, and with `collapsed_forwarding` on, every rider of a
stalled fetch stalls with it -- clients hang mid-body with headers
already received, exactly where no client-side connect or read-gap
timeout fires (the stalled-transfer trap class). The timeout is
inactivity-based and resets on every packet received, so a slow-but-moving
large object is never cut off; only a genuinely silent upstream is.

Squid's two minutes deliberately OUTLASTS the guests' `Acquire::http::Timeout`
(30 s, up to three attempts -- see `New-AptProxyBlock`). The guest gives up on a
stalled index first so the failure lands inside the sequence step's budget
while there is still time to report it, and `quick_abort_min -1 KB` above means
that giving up does not cancel the fetch: squid keeps pulling the object for
the rest of its own timeout. If the origin comes back within that window the
object is cached, so the harness's `retry_with_backoff` on the step gets a hit
instead of racing the same stall. Shortening squid to match the guest would
throw away the in-flight object every time and turn each retry into a fresh
upstream attempt.

**`collapsed_forwarding on`** pools concurrent identical fetches: when N
machines start the same uncached ISO at once, squid forwards ONE request
to origin and the other N-1 ride the in-progress fetch. Without it every
client races to origin in parallel, wasting mirror bandwidth and tripping
per-IP rate limits at releases.ubuntu.com when a swarm rebuilds. It
applies to HTTP origins and to SSL-bumped HTTPS on :3129, and has no
effect on CONNECT-tunneled HTTPS (uncacheable by definition).

**`range_offset_limit none`** changes how `Range:` requests populate the
cache. The default (`0`) forwards the partial to origin and serves it
back WITHOUT caching, so range and resumed downloads (BITS, browser
resume, `curl --range`, apt's pdiff fetcher) leave nothing behind for the
next client. `none` (unbounded) tells squid to fetch the FULL object on
the first range request and serve subsequent ranges from cache --
critical for the "many machines hit the same large ISO" case, where the
first hit may itself be a resume.

Alongside these, **`cachemgr_passwd none config`** exposes the running
config on `/squid-internal-mgr/config` without a password, which
squid-meta-exporter.sh needs so the dashboard reads the daemon's RUNTIME
state rather than the on-disk drop-in (which can be stale between an edit
and `squid -k reconfigure`). The stock `http_access allow localhost
manager` ACL in squid.conf keeps the dump off the LAN.

<a id="429f3d06-0044"></a>

### GitHub release and Helm chart pinning

**GitHub release assets** (kubectl, helm, gh, jq, terraform-provider-*,
tofu, ...) live at `github.com/<owner>/<repo>/releases/download/<tag>/<asset>`,
which 302-redirects to `objects.githubusercontent.com/<token>/...`. Both
URLs are content-addressed by tag plus asset name -- release assets are
immutable in GitHub's data model -- so both get the full-year pin. The
rule matches the whole host rather than just terraform-provider assets,
because non-extensioned binaries (raw `kubectl`, `helm`) match neither
catch-all `.zip` nor `.tar.gz` pattern.

**Helm chart packages** downloaded by `helm install <repo>/<chart>` have
URLs ending in `.tgz` (e.g.
`https://kubernetes.github.io/ingress-nginx/ingress-nginx-X.Y.Z.tgz`).
The `\.tar\.gz$` pattern does NOT match the `.tgz` short form, so without
a dedicated rule the package falls through to the catch-all
`refresh_pattern .` and revalidates on every install -- a hard failure
during a kubernetes.github.io blip. Chart packages are version-tagged and
immutable in helm's data model, so they get the same full-year pin as
GitHub release assets.

**Helm repo indexes** (`index.yaml`, fetched by `helm repo update`) are
short-lived but cacheable: 60 minutes freshness with a 20%
last-modified factor, so back-to-back cycles inside an hour hit cache
while new chart versions still land the same day. The rule is scoped to
known helm-repo hosts so unrelated YAML is not over-cached.

<a id="429f3d06-0045"></a>

### Squid access log and self-scrape filtering

The `yuruna` logformat feeds the Grafana "Recent 100 requests" panel and the
caching-proxy-parser-service. `%>A` is deliberately absent: Squid 6 turns it into a
synchronous PTR lookup, and RFC1918 addresses come back as garbage from
upstream resolvers. The User-Agent is wrapped in literal double quotes because
`%{...}>h` does not escape embedded spaces on its own.

It writes to its own file rather than the stock `access.log`, so
cachemgr/`tail` debugging keeps the default format. Two `access_log` entries
pointing at one file corrupt both, so the split is required, not cosmetic.

**Why the self-scrape exclusion matches on source, not URL path.**
squid-exporter polls three `/squid-internal-mgr` endpoints on a 15 s
Prometheus interval -- roughly 580 requests an hour of internal noise in
both `yuruna_access.log` and the "Recent 100 requests" view. The `deny` is on
`access_log`, not `http_access`, so the exporter still gets its response.

The ACL matches `src 127.0.0.1/32 ::1/128` because the exporter runs on this
VM and scrapes `127.0.0.1:3128`. A `urlpath`/`url` regex ACL cannot be
evaluated for connection-level log events that carry no parsed HTTP request
(CONNECT tunnels, pre-request TLS-bump errors); squid then writes "ACL is used
in context without an HTTP request" to `cache.log` for every such event --
hundreds per minute, burying genuine errors. `src` is always available, so the
exclusion stays warning-free. Guest traffic is LAN-sourced, so dropping
loopback removes only self-scrapes and local health probes.

Squid 7 requires the module prefix on `access_log`; without `stdio:` the
parser emits a deprecation warning at every config load.

<a id="429f3d06-0046"></a>

### Prometheus loopback only

Prometheus: loopback-only so its open UI isn't LAN-exposed; Grafana on :3000 is the entry point.

The `pool-host` scrape job discovers reachable host exporters from the aggregator instead of baking DHCP addresses into the seed. It replaces `instance` with the stable `hostId` and carries `pool` and `hostType` labels, keeping history continuous across address changes and allowing joins with pool metrics. Its allowlist retains CPU time, memory, logical-disk capacity and latency/queue families, OS identity, exporter build/collector health, and selected Hyper-V logical/root/guest processor runtime and scheduling families, plus `up` and `scrape_*`. Both deployed and newer runtime metric spellings are admitted. Unrelated Hyper-V and per-process families remain excluded. Availability and units are described in [host metrics](host-hyperv.md#42dc5bb9-0010); retaining a metric does not establish that the installed exporter publishes it.

To preview and apply only that filter to an existing monitor from the repository root:

```powershell
pwsh test/pool/Sync-PoolHostMetricsOnProxy.ps1 -WhatIf
pwsh test/pool/Sync-PoolHostMetricsOnProxy.ps1
```

An optional `-ProxyAddress` overrides the configured caching-proxy address. The command uses the existing SSH account/key and noninteractive sudo. It preserves every other configuration section, validates a temporary candidate with `promtool check config`, atomically replaces the configuration, sends Prometheus SIGHUP, and verifies the reload timestamp and success metric over loopback. Failed reloads restore the prior file and attempt a confirmed rollback reload; the command reports when confirmation is unavailable. It refuses ambiguous or customized keep rules instead of replacing a whole scrape job. No VM rebuild or package installation is needed. Running the command without `-WhatIf` changes the selected monitor; repository edits alone do not update existing monitors.

<a id="429f3d06-0047"></a>

### Loki tiered retention

Loki: loopback-only (same 0.0.0.0 default as Prometheus). Tiered retention: 30d for transitions (src=cycle) + incidents (src=incident) -- the dashboard's count_over_time Pass/Fail + incident history span a month -- and 7d for per-step events (src=event), the recent-focused drill-down (caps disk). Pre-written here because cloud-init's --force-confold preserves it through package upgrades.

<a id="429f3d06-0048"></a>

### Promtail timestamp only labels

Promtail: only timestamp in labels (client IP/URL in labels = stream explosion); positions.yaml on disk so reboots don't re-tail; /var/lib/promtail created in runcmd because the deb postinst doesn't always create it.

**Keep zot sync errors.** The JSON stage can encounter sync-extension records without an HTTP `path`; those records explain upstream retry and failure delays even when the eventual manifest request logs a successful response. The template supplies `NO_HTTP_PATH` for missing paths, and the drop stage removes only `/metrics` self-scrapes. The sentinel is retained, not dropped, so slow successful requests keep their underlying failure evidence.

<a id="429f3d06-0049"></a>

### Promtail supplementary groups drop-in

Promtail drop-in: SupplementaryGroups grants read on the upstream access logs:
- proxy:  /var/log/squid/yuruna_access.log (proxy:proxy 640)
- zot:    /var/log/zot/zot.log             (zot:zot     640)
Can't use Group= -- the promtail postinst falls back to `nogroup` (no `promtail` group created), so referencing it would fail.

<a id="429f3d06-004a"></a>

### Squid metadata exporter

Tiny script that reports `squid_offline_mode_configured` (1 if `offline_mode on` is set), `squid_listening` (1 if squid is bound to :3128), and an internet-reachability probe. Output is a Prom-format file under /var/www/html, served by apache, scraped by Prometheus (job: squid_meta).

`offline_mode` is read from squid's **runtime** config via the cachemgr pseudo-URL `http://127.0.0.1:3128/squid-internal-mgr/config`, which `cachemgr_passwd none config` in yuruna.conf permits passwordless from the localhost manager ACL. Querying the daemon means the metric reflects what squid is APPLYING right now, not what `/etc/squid/conf.d/yuruna.conf` says -- which goes stale when someone edits the file but skips `squid -k reconfigure`. If squid is down the curl fails and the metric reports 0, the correct answer: a stopped daemon serves nothing.

The internet-connectivity probe is an HTTPS GET to Google's well-known 204 endpoint (the Android / Chrome OS captive-portal canary), sent direct with no proxy chain -- this VM *is* the proxy. The 5s upper bound treats anything slower as "not really reachable" for the cache's purposes. The cache can still serve HITS offline; this metric reflects whether MISSES can be filled.

Two reasons NOT to fold this into squid-exporter:
- squid-exporter taps squid's cachemgr counters; offline_mode is a config directive, not a counter, so surfacing it would need a fork.
- When squid is DOWN, squid-exporter's metrics stop publishing and Grafana shows "No data" -- exactly when the operator needs to know whether offline_mode was supposed to be on. This exporter publishes independently of squid, so the signal survives a crashed squid.

<a id="429f3d06-004b"></a>

### zot manifest canary exporter

Times the cache's *manifest* path rather than its liveness, reads the shared Docker Hub pull budget, and publishes both as Prometheus text at `/var/www/html/zot-meta` plus a human-readable `/var/www/html/cache-health`. Driven by `zot-meta-exporter.timer`.

Served by apache, not by zot, so the numbers survive exactly the failure they describe: a zot whose sync path is wedged still answers `/v2/` and `/metrics` in milliseconds, so a probe served BY zot would report health throughout.

**Why the canary is addressed by tag.** A tag is mutable, so serving it re-runs the on-demand sync against the upstream -- the leg that stalls. A digest URL is immutable, answered from local storage, and stays fast right through an outage -- useless as a canary. The repo:tag pair is one the workloads really pull, so the number means what a reader assumes.

**Why `dotnet/sdk` specifically.** A tag probe is indistinguishable from a pull to the upstream it resolves against, so the choice of repo decides what the probe costs. `dotnet/sdk` is claimed by the scoped `mcr.microsoft.com` entry in the sync list, and that upstream meters nothing -- so the probe runs at the cadence the stall it watches deserves, rather than at the cadence a metered quota could afford. A repo that fell through to the Docker Hub catch-all would put the health probe on the one metered budget in the lab, making it a contributor to the exhaustion it is meant to report.

**Why `Accept:` is spelled out.** A registry answers a manifest request that states no preference with whatever it considers the default; for a multi-arch tag that is not the index a pull resolves, so an unspecified probe can walk a different path than the pull it stands in for.

**Two deadlines, not one.** `PROBE_MAX` (120s) bounds the probe itself -- a stall is the signal, so the cap has to sit above the client patience this exists to explain while still returning in time for the next timer tick. `CLIENT_PATIENCE` (30s) is the deadline the client actually applies: dockerd abandons a request whose *response headers* have not arrived by roughly then, and zot sends no headers until its on-demand sync resolves, so a manifest that eventually answers at 55s is a manifest every pull against it fails. Reported as its own gauge because the probe cap deliberately outlives it (measuring a stall requires surviving it), and a reading under the wide cap says nothing about survivability.

The under-patience verdict is computed in `awk`, not the shell's `test` builtin: the elapsed time is fractional and `-le` on `"30.412"` errors outright instead of answering, which under `set +e` would leave the verdict silently at 0 for every reading that carries a decimal.

**Upstream leg.** Measured without spending pull budget -- `/v2/` answers 401 on every registry here and costs no quota, which separates "the internet is slow from this VM" from "zot is slow" without becoming a second consumer of the limit the budget gauge reports. Any HTTP status proves the leg: 401 is the healthy answer for an unauthenticated `/v2/`, and treating only 200 as up would report every registry down. Metric lines are appended per probe rather than accumulated in a shell variable, because a metric line must start at column 0 and an embedded newline inside a variable carries this file's own indentation into the payload.

**Docker Hub budget.** The anonymous allowance is per egress IP, so it is spent by every guest in the lab at once, and exhausting it never surfaces as a clean 429 to a guest. Which failure it *does* produce depends on the repository: one already resident keeps serving from local storage, so nothing looks wrong until something new is pulled, and that pull then fails through the on-demand retry budget in a couple of seconds and comes back as a bare `404 manifest unknown` -- a shape that reads like a misspelled image name rather than a quota problem. The stalled-cache shape belongs to a *slow* upstream instead of a refusing one, where the pull-through sends no response headers until its sync resolves and the guest hits its own deadline first. `HEAD` on `ratelimitpreview/test` is the documented way to read the counters; it reports them without spending one. Read at most hourly (`HUB_MIN_INTERVAL`) and cached to disk in between: the counters describe a one-hour window, so a ten-minute cadence resamples the same window five extra times for a number that cannot have moved -- while minting a token each time against the upstream this file exists to keep traffic off. Between reads the previous values are republished, so the gauge keeps a value rather than dropping to zero and painting an exhausted budget.

Only a successful read is persisted. Caching a failure would republish it for the rest of the hour, turning one transient auth or egress blip into an hour of a page reporting a budget it never actually failed to read -- and an unread budget already renders as zero, which is the same shape as exhaustion.

**Authenticated vs anonymous budget.** Hub meters an authenticated sync against the account and an anonymous one against the egress IP; the two allowances differ in both size and in who else is spending them, so a remaining count means nothing until the mode is stated alongside it. A token minted with the account reports the budget zot's pulls actually spend, and the lookup is strictly best-effort -- a rotated or revoked credential must cost the reading its precision, not its existence, so any failure falls through to the anonymous request and the page says which budget it ended up reporting. The credential is passed through a 0600 netrc file rather than on the command line: argv is readable by every account on this VM through `/proc`, and the whole point of the credential's mode is that the token is not. Fields are extracted with `sed` rather than `jq` because this probe has to keep reporting on a boot where package installation is incomplete, and one field out of a flat object does not justify the dependency.

**Three distinct readings.** The MCR tag canary measures the upstream leg of an image kept resident by scheduled polling. It cannot establish that an arbitrary guest image is already stored. Warm-set data comes from the prewarm job: both `warm` and successfully completed `cold` rows count as held, while timeout/failed rows do not. The page separately reports images answered from storage and images copied in during the last run, preserving whether a guest arriving during that run would have waited.

The guest-path canary sends the same `?ns=registry.k8s.io` manifest request that containerd uses, against an image the last warm run recorded as held. This measures an on-demand upstream without scheduled polling and avoids performing a full cold synchronization on every exporter tick. Its response-header verdict is reported separately from the MCR reading; a wide-cap HTTP 200 can still exceed the guest's 30-second patience.

`TimeoutStartSec=360` accommodates two 120-second manifest probes, eight bounded upstream reads, and the Hub budget lookup. The default systemd timeout could kill a valid slow run before it publishes, leaving the previous health page visible precisely during an outage. The cap stays below the ten-minute timer interval. Published budget mode identifies authenticated versus anonymous allowance but omits the account name; `/cache-health` is readable without a login.

<a id="429f3d06-004c"></a>

### zot prewarm

`zot-prewarm.sh`, driven by `zot-prewarm.timer`, keeps the image sets a Kubernetes guest pulls resident in this cache and times every fetch, so the health page can report the path a real pull walks. Operator-facing detail -- the resolved sets, the published reading, and the cold-sync watermark -- is in [caching.md](caching.md#warm-sets-and-the-cold-sync-reading); what follows is why the unit is shaped this way.

**Why warm at all.** zot resolves a TAG by re-running the on-demand upstream sync BEFORE any local-storage check, and when the content is not already held that sync copies the whole multi-arch index before the manifest request is answered. A guest meeting that cold pays minutes per image inside a step budget sized for a warm cache. Warming on a timer moves the cost off the path a guest is waiting on; it does not remove it.

**Why the timing lives here.** This is the only reading that can show the cold path. A tag that a scheduled poll keeps resident answers from local storage in milliseconds however badly a cold sync is behaving, so a canary pinned to such a tag reports green by construction -- it measures the upstream leg and nothing about how long an image the lab does not hold takes to arrive. The prewarm run is fetching content that is genuinely absent, so its own elapsed time is the honest number.

**`PREWARM_MAX` (900s) is a ceiling, not an expectation.** It exists to stop a wedged upstream pinning the unit forever, not to express what is acceptable: a cold multi-arch control-plane image legitimately takes minutes, and cutting it short would abandon a sync the next run then has to start over.

**`COLD_FLOOR` (5s) separates a revalidation from a transfer.** Local storage answers in milliseconds, so a reading in whole seconds already means the upstream leg ran and the request moved content rather than confirming a tag the cache held.

**`Accept:` is spelled out** for the same reason the canary exporter spells it out: a manifest request stating no preference gets the registry's default, which for a multi-arch tag is not the index a real pull resolves.

**Runs are serialized with `flock`.** Two overlapping runs would race on the state files under `/var/lib/yuruna` and double the upstream work for no benefit -- and a long cold run overlapping the next timer tick is the normal case here, not an exceptional one. A tick that finds the lock held skips rather than queues.

**The warm set is resolved, never pinned in the seed.** Every input is read from the same source the guest reads, so the warm set cannot drift from the set a guest pulls; naming versions in this file would create a second pin that goes stale silently, and the staleness would surface only as a cold cache during a provisioning run. Those resolution fetches go direct: routing them through this VM's own ssl-bump listener would make a source fetch depend on the proxy it is meant to keep stocked.

The control-plane image list comes from the matching `kubeadm config images list`, since CoreDNS, pause, and etcd versions cannot be calculated from the Kubernetes version alone. Resolution falls back independently per set to the previous stored list; the freshness flag records whether the current run resolved it, so an empty unresolved result cannot masquerade as a current warm set. Every warming request includes its upstream namespace to avoid Docker Hub catch-all routing.

The six-hour timer matches zot's scheduled synchronization cadence. At boot it is armed asynchronously: a cold first run can take tens of minutes and must not hold cloud-init's ready banner open. After warming, the job refreshes the published health page immediately rather than leaving the old state visible until the exporter's next ten-minute tick.

<a id="429f3d06-004d"></a>

### Squid exporter unit

squid-exporter unit: binary go-installed in runcmd, loopback-only (Prometheus scrapes it).

<a id="429f3d06-004e"></a>

### Grafana anonymous Viewer

Grafana: anonymous Viewer (no login/sign-up); admin/admin still editable. GF_* env vars applied via systemd drop-in.

<a id="429f3d06-004f"></a>

### Grafana datasources pinned UIDs

Grafana datasources: UIDs pinned for stable cross-reference in the provisioned dashboard.

<a id="429f3d06-0050"></a>

### Grafana dashboard rewriter

Rewriter for community Grafana dashboards downloaded from grafana.com. Upstream dashboards use a $DS_PROMETHEUS templating placeholder whose embedded default points at the original author's datasource (e.g. "VictoriaMetrics Bagno") -- unrewritten, the dashboard loads but every panel renders "No data" until someone clicks through the picker. This script strips the picker, pins every panel's datasource to yuruna-prometheus, and assigns a stable uid so re-runs are idempotent. Generic across any prometheus-only dashboard; the only caller today is the Zot dashboard install below.

<a id="429f3d06-0051"></a>

### Grafana dashboard rewriter panel repairs

Beyond the datasource rebind above, the rewriter carries a numbered repair pass. Each step exists because a specific upstream panel renders blank under Grafana 13 against zot v2.x; the step numbers match the `# N)` comments in the seed's rewriter script.

**3) Drop panels querying metrics zot v2.x does not emit.** Community dashboard 20501 was authored against a newer build that emits `zot_scheduler_workers_tasks_duration_seconds_bucket`; v2.x does not, so the panel renders "No data" forever. List any further missing-metric names in `BAD_METRICS`. Template variables get the same scrub: their `label_values()` query references the same dead metric, so the toolbar dropdown would stay permanently empty and only offer a confusing UI hint.

**4) Drop orphaned rows** -- a row immediately followed by another row, or a row with no panel after it -- so no section heading outlives the pruning of its only child panel.

**5) Inline `$storageName`.** Our zot has one storage backend (`/var/lib/zot`). The community dashboard threads it through a template variable so multi-backend deployments can pick one; here that indirection only leaves the heatmap empty until a user opens the variable dropdown. The replacement is a match-any regex, which covers future backend additions without re-introducing a dropdown.

**5.5) Normalize heatmap targets to `format=heatmap`.** Upstream 20501 ships at least one heatmap target with `format=time_series`; under Grafana 13's React heatmap the panel then renders "No data" even when the underlying PromQL returns buckets keyed by `le`. Normalizing makes the datasource emit the bucket frame the panel autodetects. The same step rewrites the now-orphan `$storageName` reference in heatmap titles so it does not render literally.

**5.6) `[$__interval]` to `[$__rate_interval]` in every PromQL expression.** Grafana resolves `$__interval` as `max(scrape_interval, range / max_data_points)`, and at short time ranges (~1h on a typical heatmap panel width) it lands at 15s -- the scrape interval itself. `increase(metric[15s])` then has only ONE sample per window and PromQL returns nothing, leaving the HTTP Method Latency heatmap blank at 1h and 3h ranges even though the cache is being hit. `$__rate_interval` is guaranteed >= 4 * scrape_interval, so `increase()`/`rate()` always have enough samples; Grafana's "Variables in Prometheus" docs name it the correct interval token for rate/increase queries.

**5.7) Label-equality to label-regex for multi+includeAll variables.** Upstream 20501 ships the HTTP Method Latency heatmap with `zot_http_method_latency_seconds_bucket{method="$http_method"}` while `http_method` is declared `multi: true, includeAll: true, hide: 2`. With Grafana's default URL (`var-http_method=$__all`) and Prometheus's pipe formatter, `$http_method` substitutes to `GET|HEAD` -- but `method="GET|HEAD"` is a LITERAL string equality and returns zero series, so the heatmap renders "No data" forever, and `hide: 2` removes the toolbar dropdown so a user cannot reach a working state by hand. The pass walks every panel expression and switches `label="$var"` to `label=~"$var"` for each multi+all variable in the dashboard, covering future ones used in `=` position too.

**Storage lock latency panel replacement.** The upstream "Storage lock latency" heatmap (panel 47) does not render under Grafana 13: the Prometheus data path returns valid `le`-labeled frames, but the legacy-heatmap migration leaves this panel blank, and neither stripping its `repeat: "storageName"`, nor normalizing `target.format` to heatmap, nor cloning render fields from a working sibling heatmap (panel 30) fixes it. The rewriter REPLACES the panel with a timeseries showing P50/P90/P99 of the same metric via `histogram_quantile`, split by `lockType`: strictly more informative (the numbers are readable off the legend), and timeseries is Grafana's most battle-tested panel type. Panels are matched by query content, not panel id, so an upstream re-numbering does not break this.

The installer marks the imported board with the `community` tag, which the brand stamper reads. The rewritten stable `yuruna-` UID identifies the dashboard but cannot distinguish upstream content from a Yuruna-authored board.

<a id="429f3d06-0052"></a>

### Grafana dashboard provider

watches /var/lib/grafana/dashboards for JSON; syncs post-boot edits.

<a id="429f3d06-0053"></a>

### Grafana pull budget alert

Provisioned Grafana unified-alerting rule (`Yuruna` folder) that fires when the Docker Hub pull budget is exhausted. The condition is a PRODUCT of two gauges -- `(remaining == bool 0) * (probe_ok == bool 1)` -- rather than a reading off `remaining` alone, because the exporter publishes an unread budget as zero as well: a rule watching only that number would announce an exhausted allowance for what is actually a refused credential or a broken egress path, which is the same conflation the dashboard panel gates against.

**Why `== bool` on both halves.** It keeps the result a `1`/`0` series that always exists. Written as a plain `and`, the healthy case is an EMPTY vector, and alerting cannot distinguish an empty vector from an exporter that has stopped publishing -- so the quiet failure would look identical to health. As written, an absent series can only mean the exporter is gone, and that routes to `NoData` under its own name instead of borrowing this rule's summary.

**Pending period and evaluation cadence.** Evaluated every 5 min against a 10 min pending period. Both are deliberately far slower than the 15s scrape: the budget is re-read from Hub at most hourly and republished from disk in between, so a tighter loop only re-examines a value that cannot have moved, while 10 min still lands well inside the one-hour window the budget resets on.

**No contact point.** The rule routes to Grafana's default notification policy, and with no SMTP configured, delivery is a no-op that logs a send failure when it fires. The rule earns its place without one: it turns a number somebody has to notice into a condition with a state, a start time, and history, and its `__dashboardUid__`/`__panelId__` annotations render that state directly on the *Upstream pull budget left* panel. Adding `contactPoints:` and `policies:` to the same file is the whole change needed for real delivery.

<a id="429f3d06-0054"></a>

### Yuruna host coordinates for source fetch

Yuruna host (status service) coordinates. Baked into the seed by the platform New-VM.ps1 (Get-GuestReachableHostIp + statusService.port). The runcmd build block below sources this to fetch the collector + parser source from the LOCAL host working tree (http://IP:PORT/yuruna-repo/) -- the host repo is the source of truth, so a rebuild never waits on the private->public GitHub mirror. Same resolution as fetch-and-execute.sh. Empty IP/PORT (coordinates unavailable, e.g. status service disabled) fall back to GitHub raw.

`--no-proxy` is required on the host path: the host IP is private and this VM's own squid is in `offline_mode`, so routing that fetch through a proxy would fail. Sourcing `host.env` is safe here -- host-baked IP/PORT only, never operator free-text (a malformed value would abort the runcmd phase).

This cache VM consults the pool directory on loopback because the aggregator runs locally. The host-address resolver rejects loopback addresses returned as a host's advertised address, not loopback as the directory's own listening address. The directory location is a property of this VM's service topology and does not depend on its DHCP lease.

<a id="429f3d06-0055"></a>

### Yuruna hosts dashboard inlined

Yuruna hosts dashboard. INLINED (like squid.json) so it deploys from the local user-data -- independent of the pool-aggregator-service binary build AND of any GitHub fetch/mirror -- and so shows from first boot ("No data" until the collector is up). Keep in sync with the lintable canonical copy at test/extension/pool-aggregator-service/grafana-pool-dashboard.json.

<a id="429f3d06-0056"></a>

### Yuruna hosts dashboard panel autofit

Panel heights are fixed in dashboard JSON, and one fixed height per row does not scale across pool sizes. `yuruna-fit-pool-dashboard.py` reads the host count the collector is reporting (Prometheus + Loki on loopback), recomputes each panel's height from the dashboard grid geometry (a panel of `h` units is `38h - 8` px tall, less the chrome, the table header row, and -- on the timeline -- the x-axis and legend), re-stacks the panels below it, and rewrites `/var/lib/grafana/dashboards/pool.json` atomically. Only the three per-host panels move: the summary tiles across the top -- including "Lab token" (panel id 18), which folds in the collector's own health -- are a fixed 4 units tall and the stack starts at their bottom edge, read off the dashboard rather than assumed, because [the brand banner](#grafana-dashboard-brand-tile) sits above them and moves them down. Heights round UP: a panel a few px too tall shows blank space, one a few px too short shows a scrollbar, and only the scrollbar is a defect. The `gridPos.h` values inlined above are only the pre-collector default. A collector that is down reports no hosts, indistinguishable from an empty pool, so a zero count leaves the file untouched rather than collapsing every panel to its header. Row counts track the dashboard's DEFAULT 24h window; a wider range picked in the time picker can still surface an older host and scroll.

<a id="429f3d06-0057"></a>

### Dashboard brand identity

`/etc/yuruna/brand.env` carries the name and version the dashboards are branded with: the framework repository this VM was built from (`Yuruna`, `Yurunadev`, ...) and the VERSION of that enlistment. Seeded because the guest cannot work it out for itself -- it is handed built artifacts and never the framework repository -- and frozen for the life of the VM, like every other build-time fact about it. The host resolves both through `Get-YurunaBrandIdentity` (test/modules/Test.FrameworkSource.psm1), which reads `repositories.frameworkUrl` when the config names one and the enlistment's own origin remote otherwise -- the order the status pages resolve it in, so a page and a dashboard cannot name different repositories. Both values are reduced to characters that are safe inside the single-quoted env file; a name that survives nothing falls back to `Yuruna`, and an unreadable VERSION reports empty rather than a guess.

<a id="429f3d06-0058"></a>

### Grafana dashboard brand tile

`yuruna-brand-dashboards.py` stamps that identity across the top of every dashboard in `/var/lib/grafana/dashboards` -- the three inlined here and the community Zot dashboard alike -- as a transparent full-width text panel: the repository name, its version, and on a board that is not ours the note that it is unmodified upstream content, side by side on one line. The name and version are the pair the status pages carry in their header. It exists because a proxy outlives the bring-up that built it, and a lab running both repositories otherwise holds two proxies whose dashboards are indistinguishable.

The banner costs one line of height and no width at all. Grafana's time-range picker lives in the app's own dashboard toolbar, which dashboard JSON cannot reach, so the banner is a panel in the grid instead: a strip spanning the full 24 units above the first row, two grid units tall because a unit is 30px and a line of text does not survive that once the panel's own padding is out of it. The parts are held apart by non-breaking spaces -- a run of ordinary ones collapses to a single space in rendered HTML. Everything already on the board moves down by the banner's height and nothing is resized, so a layout that is not ours to predict needs no special case: the community dashboard, whose layout is fetched at build time, moves down like the rest whether it opens with a row header or with tiles too narrow to have given anything up.

Idempotent by construction: a dashboard already carrying the banner has only its text refreshed, never its geometry, so the timer cannot push the board further down on each pass. Files are rewritten only when their content changes and always through a same-directory rename, so the dashboard provider never reads a partial file. [The panel autofit](#yuruna-hosts-dashboard-panel-autofit) rewrites the same file, and the two agree without coordinating: the autofit stacks from the bottom edge of whatever sits above the per-host panels, which is the banner plus the summary tiles when the banner is there and the tiles alone when it is not.

<a id="429f3d06-0059"></a>

### Squid dashboard inlined

Minimal squid dashboard: panels show "No data" gracefully if metric names drift between exporter releases.

<a id="429f3d06-005a"></a>

### Cache health dashboard

Grafana dashboard (`uid: yuruna-cache-health`, "Yuruna cache health (registry path)") over the gauges the [zot manifest canary exporter](#zot-manifest-canary-exporter) publishes. Inlined into the seed for the same reason as the other dashboards here: it deploys from local user-data and renders from first boot, "No data" until the exporter's first tick.

The panel thresholds encode the point of the exporter. Manifest latency turns red at 30s because that is where dockerd abandons a pull whose response headers have not arrived -- a cache can sit green on every liveness check and still be past this line. The companion "fast enough for a real pull?" stat reads `yuruna_zot_manifest_ok_under_client_patience`: the latency stat measures the stall, this one says whether what it measured is survivable.

<a id="429f3d06-005b"></a>

### zot systemd unit

Runs zot as an unprivileged service user with ProtectSystem=strict + ReadWritePaths confining writes to /var/lib/zot (blob store) and /var/log/zot. There is no apt package for zot on Resolute, so a binary install plus a hand-written systemd unit is the simplest path. The binary lands at /usr/local/bin/zot via runcmd.

<a id="429f3d06-005c"></a>

### NetworkStorage pool replication config

networkStorage pool (ypool-nas) service replication: config + SMB credential + the timer-driven rsync of observability data to the NAS. All values are baked by New-VM.ps1 from the host's networkStorage pool config + vault (empty / REPLICATE=false when off).

The replication job copies Loki, Prometheus, and Grafana observability data into `<mount>/hosts/<hostId>/services/caching-proxy-service/`, beside the host's `test-cycles/` directory. Rebuildable Squid/zot caches and Promtail's tail cursor are excluded. The job is best effort and publishes mount/copy status at `/ypool-nas-status` for diagnosis without SSH. Older `<hostId>/services/` roots are not read automatically; recovery from them is a manual operation described in [pool storage](pool-storage.md).

`yuruna-config-fetch.sh pool` owns the mount and rotated mTLS-fetched credential. Replication triggers a best-effort refresh before checking `mountpoint -q`; `findmnt --target` can incorrectly accept the enclosing root filesystem when the NAS itself is not mounted.

<a id="429f3d06-005d"></a>

### NAS cifs credentials

cifs credentials (0600 root). The networkUser account -- the single NAS account, ACL-scoped storage-only by the operator (write access to the share, nothing else).

<a id="429f3d06-005e"></a>

### Config service client materials and NAS credential fetch

The NAS connection info and password are fetched from the host's config
service at boot **and hourly**, so a rotated NAS password reaches this
running VM without a rebuild. The client certificate chains to *this*
host's Config CA, so the service serves only this host's VMs. The PEMs
are baked base64 (`encoding: b64`) to survive YAML, and single-quoted so
an empty value -- a client cert that was never minted -- parses as `''`
and the runcmd gate skips the fetch instead of erroring.

`yuruna-config-fetch.sh <stash|pool>` is the single owner of the
matching mount and credential file. It is best-effort by design and
never fails hard: every exit path writes a breadcrumb to
`/var/www/html/config-fetch-<name>-status` (Apache serves
`/var/www/html`), making "configured but not mounting" diagnosable
without SSH, mirroring `ypool-nas-status`.

Per-name behavior: **stash** mounts read-only for the aggregator's scan;
**pool** mounts read-write so `ypool-nas-replicate.sh` can rsync into it,
at the exact credentials path that script already reads.

Four traps this script encodes:

- **Boot race.** At guest boot the host config service may not be
  accepting yet, because host bring-up races VM boot. Five short retries
  beat waiting an hour for the next timer tick; the call is idempotent,
  so the burst is harmless on the hourly path, where it succeeds on the
  first try.
- **Stale baked host IP.** When the fetch yields nothing, a probe of
  `http://<host>:<statusPort>/livecheck` separates "host reachable but
  the config service is down" from "host unreachable at the baked IP"
  (which a host DHCP change causes), so the breadcrumb names the actual
  repair.
- **Unresolvable NAS hostname.** The share's server name is resolved on
  the *host*, where it may be an alias only the host knows --
  `New-LocalLabStorage` points `ypool-nas` at the host's loopback
  address, which resolves to nothing in the guest and fails the mount
  with `cifs_mount -111`. In that configuration the host *is* the
  storage server, so when the guest cannot resolve the name the mount
  adds `ip=<host>` using the address the config service just answered on
  -- known-good by construction.
- **No `iocharset=utf8`.** `nls_utf8` is absent on the minimal cloud
  kernel and the mount fails with `error(79)`. The on-disk names are
  ASCII, so the option is simply omitted.

`printf %s` writes the password literally, with no shell re-parsing, so
vault special characters survive into the cifs credentials file intact.
Remount happens only when the reported version changed or the mount
point is not currently mounted.

Sourcing note: `/etc/yuruna/host.env` holds only host-baked
`YURUNA_STATUS_SERVICE_IP`/`PORT` (no operator free-text), so sourcing it
is safe. Operator-supplied env files must instead be sed-extracted.

The stable TLS hostname (SAN) is mapped to the host's current IP via
`curl --connect-to`, so a host DHCP change never invalidates the server
leaf.

<a id="429f3d06-005f"></a>

### Internal authentication key

the internal authentication key that gates remote control, the aggregator's POST /ingest push surface, and cross-host credential fetch. Baked into `/etc/yuruna/internal-auth.key` (the `INTERNAL_AUTH_KEY_PLACEHOLDER` substitution) by New-VM from the building host's vault -- logical user `internal-auth-key`, with the older `lab-auth-token` and the legacy `pool-auth-token` vault entries accepted as fallbacks so a host enrolled under either logical name keeps working; the daemons reading the file fall back to the older `/etc/yuruna/lab-auth.token` path when the new one is absent, so a VM still carrying the older path keeps working until it is rebuilt. When the vault holds none of the three, New-VM mints a random internal authentication key and stores it before baking, so a proxy is never built with an empty key; an empty-key proxy (mints no control proofs, /ingest answers 503, dashboard Lab token tile shows "off") is a diagnosable failure state, not a normal early one. The aggregator trims surrounding whitespace. Mode 0640 root:proxy: readable by the proxy-run aggregator, not world-readable.

<a id="429f3d06-0060"></a>

### runcmd errexit leaks across items

cloud-init concatenates every `runcmd` item into ONE `/bin/sh` script. A `set -e` inside any item therefore stays in effect for every later item, and a single non-zero exit aborts the whole remaining phase -- on this seed the CA generation, ssl_db init, prewarm, exporters, monitoring stack, and ready banner then silently never run. The failure is invisible in `systemctl` output because `write_files` still ran; only `cloud-init status --long` surfaces it.

Two conventions keep that contained, both load-bearing rather than stylistic:

- **Wrap any `set -e` block in a subshell** `( ... ) || echo "== YURUNA: ... FAILED =="`. The parentheses keep errexit local and give the step its own diagnosable failure line. A subshell also scopes a bare `exit 0`, which at top level would end the entire runcmd script rather than just that step.
- **Append `|| true` to commands that may legitimately fail**, notably `systemctl start squid`. Without it a failed start aborts the rest of the phase and leaves a start failure with no diagnosis behind; with it, the bind-wait step below is what reports and diagnoses the failure.

<a id="429f3d06-0061"></a>

### Stop squid before CA bootstrap

Stop the squid that apt's postinst started: it either FATALs (yuruna.conf references ca.pem before we generate it) or runs on a partial/default config. Don't run `squid -z` here -- it also parses yuruna.conf and FATALs on the missing cert, leaving nothing but a scary log entry.

<a id="429f3d06-0062"></a>

### SSL-bump capable squid binary

Ubuntu 26.04 ships squid as a Debian *alternative*. The `squid` package installs
`/usr/sbin/squid-gnutls` (a GnuTLS build with no ssl-bump, no `at_step`, and no
`security_file_certgen`); `squid-openssl` installs `/usr/sbin/squid-openssl`; and
`/usr/sbin/squid` is a symlink through `/etc/alternatives/squid`.

apt pulls `squid` in automatically alongside the `squid-openssl` this seed asks
for, and dpkg configures `squid` **first** -- so its postinst starts
`squid.service` while the GnuTLS binary is still the selected alternative. That
start FATALs on the ssl-bump config, and the failed unit is never retried. The
FATAL names `at_step`, which reads like a squid syntax change and sends a first
diagnosis chasing a nonexistent one; the actual fault is binary selection.

So the seed pins the alternative explicitly rather than trusting install order,
verifies the selected binary reports `--with-openssl`, and installs
`squid-openssl` as a fallback if it does not. It then runs
`systemctl reset-failed squid`: the doomed postinst start leaves the unit
failed, and without the reset systemd's restart limiter refuses the real start
at the end of `runcmd`.

<a id="429f3d06-0063"></a>

### SSL-bump CA bootstrap

both steps idempotent so re-runs don't rotate the CA (rotating would orphan guests that already trusted it). Private key stays proxy:proxy 700; public cert served by Apache. CN includes a timestamp to distinguish deliberate rebuilds.

**Why `-addext` and not `-extensions v3_ca`.** `-extensions v3_ca` silently produces a non-CA certificate when `/etc/ssl/openssl.cnf` on the installed openssl 3.x build lacks a `[ v3_ca ]` section. The result loads, but squid rejects it -- "No valid signing certificate configured for HTTP_port [::]:3129" -- and never binds the port. The `-addext` form is self-contained. `keyCertSign` is required for ssl-bump's per-host leaf minting.

**Why the CommonName is hard-truncated to 64 characters.** X.509 caps CommonName at 64 characters (`ub-common-name`) and openssl rejects the WHOLE request past it: "ASN1_mbstring_ncopy: string too long ... maxsize=64". The failure is silent end-to-end -- no `ca.pem` is written and squid can never bind :3129. `$(hostname)` alone already runs close to the cap, so any literal prefix overflows it; the script truncates with `printf '%.64s'` rather than trusting the components to stay short.

<a id="429f3d06-0064"></a>

### Pool-aggregator service TLS leaf

pool-aggregator-service TLS leaf: mint a server cert for the aggregator's :9400 surface (metrics + ingest), signed by the squid CA above (reused -- no new CA), so the LAN hop is encrypted + authenticated. Idempotent (no rotate). SAN carries the proxy's LAN IP (runners connect by IP) + 127.0.0.1 (loopback Prometheus). Key stays proxy:proxy 600 (the aggregator runs as proxy). Best-effort: a mint failure leaves no leaf and the aggregator falls back to plain HTTP.

<a id="429f3d06-0065"></a>

### Resolve pool dashboard aggregator URL

Resolve the Yuruna hosts dashboard's aggregator base URL. The timeline's "open cycle results" and "share cycle results" data links point at this proxy's /go/cycle and /go/cycle-share redirects, which resolve each host's CURRENT IP server-side, so the links survive a host IP change. The proxy's own LAN IP is known only at boot (DHCP), so substitute it here. Idempotent: a re-run finds no placeholder. The dashboard provider re-syncs the edited file, so this may land before or after grafana-server starts.

**Always plain http, even once the aggregator has its TLS leaf.** The dashboard links only reach the aggregator's `/go/*` redirects, which land the operator's browser on plain-http host status pages. An https hop here would put a proxy-CA interstitial (operator browsers do not trust the proxy CA) in front of every host click while protecting nothing the next hop does not already carry in clear. The aggregator answers both protocols on :9400, so token-bearing clients keep their TLS.

<a id="429f3d06-0066"></a>

### Squid ssl_db initialization

security_file_certgen's `-c` is create-new and errors if the DB already exists, so the existence check guards re-runs. DB holds leaf certs minted per SNI hostname -- 4 MB is generous (each entry ~1 KB).

The `install -d` for /var/lib/squid is NOT redundant: on Ubuntu the squid-openssl postinst does not guarantee this directory, and security_file_certgen's Create() makes only the leaf `ssl_db/` dir, not the parent. Without it the helper FATALs with "Cannot create /var/lib/squid/ssl_db", sslcrtd children crash-loop on every spawn, squid bails with "The sslcrtd_program helpers are crashing too rapidly, need help!" and squid-parent blocks restart for 3600s. Running as `proxy` avoids a follow-up chown and confirms write access.

<a id="429f3d06-0067"></a>

### Publish squid CA cert

Publish the CA public cert at http://<cache>/yuruna-squid-ca.crt so guests can fetch and trust it during install. Only the public cert is copied -- ca.key stays in /etc/squid/ssl_cert/. Mode 644 is deliberate: RFC1918 reachability is enforced at the network layer (the host switch/bridge/NAT), so trust distribution works without an extra cachemgr-style `Require ip` drop-in.

<a id="429f3d06-0068"></a>

### Publish pool CA cert

Publish the SAME CA under a pool-specific name so a runner can pin the pool-aggregator-service's TLS leaf (it is signed by this CA) without coupling to the squid CA filename. Public cert only; the key never leaves /etc/squid/ssl_cert.

<a id="429f3d06-0069"></a>

### Pre-warm the cache

security.ubuntu.com rate-limits linux-firmware (~330 MB) hard enough that every cold guest install 429s on it. Pre-fetching via the local proxy puts it in squid before any guest asks, so the first-ever install serves from cache. Pull the HWE meta too so kernel, modules-extra, headers, and microcode .debs land alongside.

Wait up to 60s for squid's listener. apt's postinst usually has it up, but start can be slow on first boot.

<a id="429f3d06-006a"></a>

### Route VM apt through local squid

Only NOW route this VM's own apt through local squid -- squid is confirmed listening, so the self-proxy loop is safe. Writing this drop-in during write_files (before `packages:` runs) deadlocks apt: it fetches squid itself through 127.0.0.1:3128, which is not listening yet, and the install bombs with Exit 100.

<a id="429f3d06-006b"></a>

### Prewarm download loop

Each call: --reinstall --download-only first (forces re-fetch of already-installed packages like linux-firmware); fall back to plain download-only for not-yet-installed packages (linux-generic-hwe-24.04 and friends). `|| true` on the fallback so one miss doesn't abort the loop.

<a id="429f3d06-006c"></a>

### Reclaim apt cache after prewarm

Squid now has the large .debs cached under /var/spool/squid. Clear /var/cache/apt (squid's store is separate) to reclaim ~1 GB.

<a id="429f3d06-006d"></a>

### Remove prewarm apt proxy dropin

Remove the apt proxy drop-in so future apt inside this VM doesn't loop through its own squid. Guests still reach squid at 3128 over network.

<a id="429f3d06-006e"></a>

### Flip squid into offline mode

Flip squid into offline_mode now that prewarm is done. With offline_mode on, squid serves cached objects without contacting origin -- a hit returns stored content, a miss returns 504. This enables the "fully disconnected if everything is cached" workflow: guests can apt-install against this proxy with no internet on the host.

Must be AFTER prewarm -- with offline_mode on, a cold-cache first request returns 504 and prewarm populates nothing. Dropped as a separate conf.d file so an operator can refresh against origin by removing that one file and running `squid -k reconfigure`.

<a id="429f3d06-006f"></a>

### offline_mode echo YAML mapping trap

Single-quote the echo so YAML doesn't parse `cache:` as a mapping key. cloud-init's shellify() chokes on a dict in runcmd and aborts the ENTIRE runcmd phase -- which happened once, leaving a VM with Apache's default page, no cachemgr, no offline_mode, no monitoring even though write_files and packages ran.

<a id="429f3d06-0070"></a>

### Build squid-exporter and caching-proxy-parser-service

Build and install squid-exporter + caching-proxy-parser-service. No apt package for either; `go install` (squid-exporter) and `go build` against fetched source (caching-proxy-parser-service) keep this cross-arch path working -- amd64 on Hyper-V/KVM, arm64 on UTM, no URL guessing. squid-exporter is pinned to v1.13.0, the cutoff release: it dropped legacy `cache_mgr://` URI support and switched to Squid 7's `/squid-internal-mgr/` HTTP path. Ubuntu 26.04 (Resolute) ships Squid 7.x, which rejects the old URI; earlier pins (v1.10.5 and below) install fine and scrape clean (squid_up still publishes) but report squid_up=0 and zero counter metrics because the request path to squid is unreachable -- every Grafana panel querying `squid_client_http_*_total` ends up empty. See https://github.com/boynux/squid-exporter/releases/tag/v1.13.0 for the cache_mgr -> squid-internal-mgr swap. Both runs happen AFTER the prewarm proxy cleanup so the Go module fetch (HTTPS to proxy.golang.org + GitHub) doesn't traverse squid -- HTTP squid can't cache HTTPS without SSL-bump.

The same build phase stages the pool aggregator and caching-proxy management daemon with their complete Go dependency trees. `extension-sdk` is a separate module and must remain a sibling of each daemon's build directory, matching its relative `replace` directive. The staged tree also includes transitive packages such as `labgate`'s i18n dependency. Every destination directory must exist before `wget -O` writes source files.

<a id="429f3d06-0071"></a>

### Purge Go toolchain after builds

Reclaim ~400 MB: the Go toolchain is only needed for the builds above, and both squid-exporter and caching-proxy-parser-service are static binaries.

<a id="429f3d06-0072"></a>

### Start the monitoring stack

daemon-reload picks up the squid-exporter unit + grafana-server drop-in written via write_files. Grafana is restarted (not just enabled) so the anonymous-Viewer env vars take effect even if the deb postinst already started it.

<a id="429f3d06-0073"></a>

### Start the caching proxy management service

`caching-proxy-service` is the management plane for this VM: a read surface over
squid, zot and the two operator switches, and the beacon that puts the proxy in
the pool's **Extension hosts** row like every other service. Enabled with
`|| true`, the same as the two Go services beside it -- a management plane that
fails to start must not fail the boot of the VM whose traffic it does not carry.
The proxy keeps serving either way; what is lost is the ability to ask this VM
about itself, and the offline / no-upstream switches go back to being SSH-only.

The daemon reads its flags from an environment file so an operator can retarget it without editing a unit that an upgrade will replace. Seed values are extracted with `sed` instead of sourcing the file; malformed shell quoting must not abort the boot phase. The aggregator lives on this VM, but presence beacons use its LAN address, preferably HTTPS. The aggregator derives the advertised service address from the request's source and rejects loopback, so a beacon sent through `127.0.0.1` would never advertise this extension. The beacon can fall back to HTTP when no TLS leaf is available.

<a id="429f3d06-0074"></a>

### Enable squid metadata exporter timer

Squid meta exporter: timer drives a oneshot that writes /var/www/html/squid-meta every 30s. Started AFTER apache2 (already active by the packages phase) so the first scrape doesn't 404.

<a id="429f3d06-0075"></a>

### Prime squid metadata exporter once

Run the script once immediately so /var/www/html/squid-meta exists before Prometheus's first scrape, avoiding a 15-second "No data" window on the dashboard at boot.

<a id="429f3d06-0076"></a>

### Enable zot metadata exporter timer

Armed here, primed after the zot install below: a first run against a registry that does not exist yet would publish a DOWN reading as the service's opening data point.

<a id="429f3d06-0077"></a>

### Enable caching-proxy-parser service

caching-proxy-parser-service fails closed (the binary may not be present if the build above failed); `|| true` keeps the rest of runcmd going so loki+promtail+grafana still come up.

<a id="429f3d06-0078"></a>

### Enable pool-aggregator service

pool-aggregator-service: read-only pool view. Soft-fail like the parser -- the binary may be absent if the build above failed; prometheus already has the pool-aggregator-service scrape job (it just reads 'down' until the daemon is up).

The unit's `ExecStart` carries `-auth-token-file /etc/yuruna/internal-auth.key -host-ttl 24h -lab-token-rotate 60s`. The token file holds the internal authentication key (see "Internal authentication key" above); the daemon falls back to `/etc/yuruna/lab-auth.token` when that path is absent. `-lab-token-rotate` drives the lab-token exchange: the aggregator mints a 6-character lab connection token (lowercase a-z0-9), rotates it on that interval, surfaces it on the dashboard's "Lab token" tile (via the `yuruna_pool_lab_token` info gauge), and serves the open endpoint `POST /api/v1/lab-token` on :9400 (body `{"labToken":"<code>"}` -> 200 with the internal authentication key; 400 malformed, 403 unknown/expired code, 429 per-IP throttle, 503 exchange disabled). A displayed code stays redeemable for about three rotations; `0` disables the tile and the exchange. Exchanges are counted in `yuruna_pool_lab_token_exchanges_total` and every attempt is audited (aggregator log + Loki, label src="lab-token"). A host enrolls with `pwsh test/lab/Set-LabToken.ps1 -LabToken <code>`.

How long a host stays in that view after its last contact is `-host-ttl` in the unit's `ExecStart` (default `24h`): change it and run `systemctl daemon-reload && systemctl restart pool-aggregator-service` -- no rebuild. The `daemon-reload` is load-bearing; without it systemd restarts from its cached copy of the unit and the old value silently stays in force (the same trap [caching.md](caching.md) documents for the squid units). A non-positive value falls back to 24h. A binary that predates the flag exits immediately on it and `Restart=on-failure` turns that into a crash loop, so re-provision such a proxy first.

Restarting is not free, and for this knob it partly works against you. On startup the aggregator re-seeds host stubs from the Loki presence feed over `-rehydrate-window` (default `168h`, **not** the host TTL) and stamps each stub as last-seen *now*, so a machine gone for days comes back as a `Reachable=false` row and then survives a full host TTL of failed probes: the restart you perform to shorten the TTL re-creates the rows you were trying to remove. A restart also resets the degraded/alert hysteresis latch. So `-host-ttl` sets the steady-state window; to evict a specific decommissioned host deterministically use `Remove-PoolHost.ps1` / `POST /api/v1/forget-host`, which also clears its cumulative counters.

This 24h is neither the dashboard's default time range above nor the last-seen window `Remove-PoolHost.ps1` enforces before it will forget a record. Three different 24-hour values, three different meanings.

<a id="429f3d06-0079"></a>

### Pool intent store seeding

Yuruna pool intent store: a bare git repo pooled hosts clone + pull READ-ONLY over HTTP (the yuruna-pool-intent apache conf) to learn pool membership + desiredState. The admin CLI (run on the proxy) pushes intent here. Seeded with an empty, schema-valid pools.yml on 'main' so the first clone is non-empty and deterministic. The post-update hook keeps the dumb-HTTP info current on every push. Idempotent (a re-run skips an existing repo) and soft-fail (each fallible step is `|| true`), so it can never abort the phase.

Create the repository only while the pool NAS is mounted. Initializing it under an unmounted mountpoint would put intent on the VM disk; a later mount would shadow that repository and strand updates made in between.

<a id="429f3d06-007a"></a>

### Wait for grafana-server to bind

Wait for grafana-server to bind :3000 and dump the journal if it doesn't. On a slow first boot, grafana can take ~15s to come up after `restart` returns. Without this check, a failed start surfaces only when an operator tries the dashboard and gets "connection refused" -- by which time cloud-init logs may be rotated. Mirrors the squid:3128 diagnostic net so both failure modes surface the same way in /var/log/cloud-init-output.log.

<a id="429f3d06-007b"></a>

### Enable yuruna hosts dashboard panel autofit

Enable the timer that keeps the Yuruna hosts dashboard's per-host panels sized to the pool (see "Yuruna hosts dashboard panel autofit" above). It first fires 3min after boot -- by then the collector has polled the pool at least once -- and every 5min after, so a host that joins or leaves shows up within one tick plus the dashboard provider's 30s reload. `--now` also runs it once here: two loopback queries, a no-op on a pool that has not registered yet.

<a id="429f3d06-007c"></a>

### Install community Zot dashboard

Install the community Zot dashboard (Grafana ID 20501) alongside the hand-crafted Yuruna caching-proxy-service dashboard. The write_files rewriter (see "Grafana dashboard rewriter" above) pins it to yuruna-prometheus with a stable uid and a friendly title, so re-runs are idempotent. The dashboard provisioner under /etc/grafana/provisioning/dashboards/yuruna.yaml picks the file up on its next 30s tick. The `else` branch keeps cycling: a transient grafana.com outage degrades to "missing extra dashboard" rather than failing the whole runcmd phase.

<a id="429f3d06-007d"></a>

### Enable grafana dashboard brand tile

Enable the timer that keeps [the brand tile](#grafana-dashboard-brand-tile) on every dashboard, then stamp them once here. Last of the dashboard steps, so the community Zot dashboard is already on disk and gets branded in the same pass as the three inlined ones. The explicit `start` is what brands them now -- enabling the timer only schedules the next tick, and a proxy whose dashboards are anonymous through the first minutes of its life is exactly the window an operator watches it in. The timer (2min after boot, every 15min after) is the backstop for a dashboard that lands later; it rewrites nothing when there is nothing to change. The `|| echo` degrades a failed stamp to unbranded dashboards rather than failing the runcmd phase, and it is a block scalar because the message carries a colon-space, which a plain YAML scalar would read as a mapping.

<a id="429f3d06-007e"></a>

### Enable NAS replication timer conditionally

networkStorage pool (ypool-nas) service replication: enable the timer only when the seed was built with replication configured (REPLICATE=true). Read it with an exact-line grep, NOT by sourcing -- a malformed value would abort the whole runcmd phase, since the `.`-parse error fires before any `|| true`. The block scalar dodges the colon-space YAML trap; grep dodges the source-time abort.

<a id="429f3d06-007f"></a>

### Verify promtail supplementary groups

Verify promtail picked up BOTH supplementary groups. The drop-in writes "SupplementaryGroups=proxy zot"; missing either keeps the corresponding Recent-100 panel empty. The check must verify each group explicitly: grepping only for `proxy` lets a missing `zot` group slip past observability.

<a id="429f3d06-0080"></a>

### First-boot security upgrade

unattended-upgrades + the daily apt timers keep pulling fixes from here on; this run flushes the backlog between the cloud image's build date and boot day. Routed through 127.0.0.1:3128 (squid is up by now and the prewarm-proxy drop-in already enabled this VM's apt-via-self loop) so the upgrade hits cache for anything other guests have pulled before. `|| true` so a transient archive.ubuntu.com hiccup cannot fail the whole cycle -- the daily apt-daily-upgrade.timer retries within 24 h.

<a id="429f3d06-0081"></a>

### Confirm apt daily timers armed

Confirm the timers that drive the 24-hour cadence are armed. If the apt package's postinst did not enable them (rare on Ubuntu but seen on minimized cloud images), surface a clear breadcrumb so an operator notices BEFORE CVEs pile up.

<a id="429f3d06-0082"></a>

### zot install binary and activation

zot install (binary fetch + systemd activation). ZOT_VERSION is pinned for reproducibility. To bump: read https://github.com/project-zot/zot/releases, verify the asset names still match `zot-linux-{amd64,arm64}` (NOT `-minimal` -- the sync extension is required for on-demand pull-through caching), then change ZOT_VERSION here. The binary download goes DIRECT to GitHub (not through this VM's own squid -- chicken-and-egg) and is one-shot per VM build, so the ~220 MB transfer doesn't recur.

With no Docker Hub account configured, remove `credentialsFile` from zot's JSON before deleting the credential file. An interrupted sequence then leaves an unused file rather than a configuration naming a missing file that prevents zot from starting. JSON rewriting must preserve `registries[]` order because that array is the upstream routing table. Arm prewarming after activation instead of waiting for the first cold set during cloud-init.

<a id="429f3d06-0083"></a>

### Service readiness summary

A final self-check that prints one line per service, port, and on-disk artifact
the operator -- and `Test-CachingProxyService.ps1` -- depends on. Without it a
partially-failed boot looks identical to a good one until something downstream
breaks, far from the cause.

The summary includes the first manifest canary and warm-set reading because `/v2/` liveness alone cannot show a broken manifest path or an empty rebuilt cache. Match residency lines by leading-whitespace shape rather than a fixed indentation count, so harmless page nesting changes do not hide them from the boot log.

<a id="429f3d06-0084"></a>

### Ready banner YAML mapping trap

Single-quoted: the bare `: ` after "ready" makes YAML parse the scalar as a mapping, shellify() gets a dict instead of a string, and the ENTIRE runcmd phase aborts (CA gen, ssl_db init, prewarm, squid-exporter, monitoring -- none run). Same trap as the offline_mode echo above, and equally silent in systemctl output because write_files still ran; only `cloud-init status --long` surfaces the TypeError.

---

<a id="429f3d06-0085"></a>

## Stash-service seed topics

Topics for `host/vmconfig/stash-service.base.user-data`, reached from the seed as
`# --- REGION: https://yuruna.link/429f3d06-0086`.

<a id="429f3d06-0086"></a>

### Host agent runs first

On a bridged network the host observes no DHCP lease, so it cannot report this VM's address until the guest agent answers -- and every later runcmd step can run for minutes. The agent overlay goes first so host-side discovery does not wait on the rest of the boot.

<a id="429f3d06-0087"></a>

### Bring-up driven by systemd, not runcmd

The bring-up is a script driven by a systemd unit rather than inline `runcmd` steps. `runcmd` is a PER-INSTANCE cloud-init module and this seed's instance-id is a constant, so `runcmd` gets exactly ONE attempt in the life of the VM: a bring-up interrupted partway -- the VM stopped while cloud-init is still compiling the daemon -- is never retried. Every later boot skips it, cloud-init still reports `status: done, errors: []`, and the VM stays permanently half-built with no daemon, no unit, and nothing naming the cause. Driven by systemd instead, an interrupted bring-up finishes next boot.

The script is therefore idempotent by construction and safe to re-run; it is the ONLY thing that installs the daemon. Each stage sets `+e` and reports rather than aborting, so a stage that cannot finish (an unreachable share, a host status service that is down) leaves the later stages free to do what they still can.

<a id="429f3d06-0088"></a>

### Stash NAS cifs mount options

The mount is persisted via `/etc/fstab` so it survives reboot and so systemd exposes a `mnt-ystash\x2dnas.mount` unit the daemon can order `After=`. Readiness is checked with `mountpoint -q`, NOT `findmnt --target`, which resolves a non-mount to its enclosing mount and false-passes.

The modes are deliberately open (`file_mode=0666`, `dir_mode=0777`) rather than restrictive. The server maps the cifs mount mode onto the created object's NTFS ACL, so `dir_mode=0700` would lock every folder the VM creates to the single creator -- even though the parent stash share grants all users full control -- and other pool peers (and the host) then cannot list the stash. Matching the open parent is the correct choice, not a loosening.

`noperm` stops the client from blocking the daemon on a surprising owner mapping. There is deliberately **no** `iocharset=utf8`: `nls_utf8` is absent on the minimal cloud kernel and the mount fails with `mount error(79)`; stash on-disk names are ASCII.

A Linux guest often cannot resolve a bare NetBIOS name (e.g. `wserver`), so `ip=` -- resolved on the host at bake time -- lets cifs connect without name resolution.

---

<a id="429f3d06-0089"></a>

## Download-agent-service seed topics

Topics for `host/vmconfig/download-agent-service.base.user-data`, reached from the seed as
`# --- REGION: https://yuruna.link/429f3d06-008a`.

<a id="429f3d06-008a"></a>

### PowerShell install is best effort

PowerShell is installed for the **Windows 11 family only**. That family has no wget-able URL: Microsoft mints a short-lived signed one per request, and Fido is what asks for it -- under pwsh, because Fido is a PowerShell script.

The step is best effort on purpose. With no interpreter the daemon reports the family absent and every host keeps its current path (Hyper-V and UTM run Fido themselves, KVM asks for a manual download), so nothing in this step may fail the build.

Microsoft's prod apt repo is tried first. It publishes a suite per Ubuntu release but does not always ship a `powershell` package IN that suite, and an apt install that resolves no candidate leaves the guest with no interpreter and nothing in the log worth reading -- so the candidate is checked (`apt-cache policy`) rather than assumed. The release tarball, distro-independent and what the sibling guest bring-up scripts use, covers the releases the repo has not caught up with.

Latest-stable is resolved by following `/releases/latest`, not the GitHub API: unauthenticated API calls are capped at 60/hr lab-wide.

<a id="429f3d06-008b"></a>

### PowerShell tarball hash verification

The tarball is verified against the release's published hashes before unpacking, because this interpreter runs Fido with the daemon's privileges.

The `hashes.sha256` asset is UTF-16 LE (Windows-generated), so it is normalized to UTF-8 before parsing -- a byte-order-mark probe picks the branch.

A **mismatch aborts** the install and leaves nothing behind. A hashes file that cannot be fetched or parsed only **warns** and proceeds, so a GitHub blip does not cost the family.

<a id="429f3d06-008c"></a>

### Fido pinned tag and hash

Fido is pinned to the same tagged release and verified against the same SHA-256 the host scripts pin (`host/*/guest.windows.11/Get-Image.ps1`). Fido runs with the daemon's privileges, so an unpinned moving ref would be an unchecked remote-code hop; a hash mismatch therefore leaves **no file behind** rather than an unverified one.

Like the PowerShell step this is best effort, and the step's last line names the resulting state outright -- because "the agent never serves Windows 11" and "the agent is fine, this lab just has no Fido" look identical from a host.

The destination must stay one of the paths the daemon searches when `--fido-script` is empty. Moving it elsewhere disables the family **silently**, since a missing Fido is a supported state rather than an error.

---

<a id="429f3d06-008d"></a>

## Maintenance notes

- New topics: add a `### <topic name>` section here, then in user-data
  run `tools/Invoke-DocAnchor.ps1 -Update -Path docs/vmconfig.md`, then emit a
  single `# --- REGION:` line using the assigned semi-GUID.
- Removed topics: drop the section here AND the one-line reference in
  every guest where it appeared. Search the semi-GUID under `host/` to find
  call sites.
- The recommended order list at the top of this file is the
  authoritative convention; deviating in a specific guest is fine when
  there's a real dependency, but document why in a one-line comment
  beside the out-of-order step.

<a id="429f3d06-008e"></a>

### Caching-proxy-service seed maintenance

- New topic: add a `### <topic name>` section under
  [Caching-proxy-service seed topics](#caching-proxy-service-seed-topics) above,
  assign it a permanent anchor, then add one `# See` pointer to that semi-GUID
  at the matching indent in the user-data.
- Removed topic: drop the section here AND the one-line pointer in the
  user-data. Search the semi-GUID across `host/vmconfig/` to find its call sites.
- Comments inside deployed artifacts (squid.conf, embedded scripts, systemd
  units) intentionally stay in the user-data; document subsystem-level rationale
  here and leave the line-level "why" beside the code it ships with.

<a id="429f3d06-008f"></a>

### Adding a new placeholder

1. Add the literal `<NAME>_PLACEHOLDER` token to
   `host/vmconfig/ubuntu.server.base.user-data` at the appropriate spot.
2. Add the matching entry to every `New-VM.ps1` caller's `-Replacement`
   hashtable. The safety net catches any caller that forgot.
3. If the value derives from the repo (a new bundled helper script), add
   it to `Get-YurunaGuestScriptBase64` and let `New-CloudInitUserData`
   auto-populate.

<a id="429f3d06-0090"></a>

### Adding a new platform overlay

1. Create `host/vmconfig/ubuntu.server.<platform>.overlay.yml` with the
   four anchor headers (empty payloads for anchors the platform doesn't
   use).
2. Add a `New-VM.ps1` under `host/<platform>/guest.ubuntu.server.{24,26}/`
   that calls `New-CloudInitUserData` with the new overlay path.
3. The merger validates anchor coverage at merge time -- a missing anchor
   in the overlay raises.

---

<a id="429f3d06-0091"></a>

## Image acquisition and provisioning

Rationale for the `Get-Image.ps1` / `New-VM.ps1` image pipeline that is
shared across hosts but too long to keep inline. (The download
skip-if-same-source guard and the image sentinel's Last-Modified capture
live in
[guest-image-setup.md -> Skip-if-same-source guard](guest-image-setup.md#skip-if-same-source-guard).)

<a id="429f3d06-0092"></a>

### macOS UTM qcow2 punchhole alignment

The macOS UTM infra `Get-Image.ps1` scripts (`guest.caching-proxy-service`,
`guest.stash-service`) keep the final artifact as **qcow2** instead of
converting to raw:

- UTM's QEMU backend boots qcow2 natively, so no raw conversion is needed.
  (Hyper-V converts to VHDX because it cannot boot qcow2 -- a genuine
  hypervisor difference, not drift.)
- qcow2 is also **required for correctness** on macOS: UTM attaches
  read-write disks with `discard=unmap,detect-zeroes=unmap`, and QEMU's
  macOS file-posix backend services those discards via
  `fcntl(F_PUNCHHOLE)`, which rejects any request not aligned to the APFS
  4 KiB block size with `EINVAL` ("Invalid argument"). A raw image punches
  holes at the guest's 512-byte discard granularity and trips that; qcow2
  only ever punches at its 64 KiB cluster boundaries, which are always
  4 KiB-aligned. See `feedback_macos-qemu-punchhole-alignment.md` (the
  memory capture of this trap class).

Both UTM infra pipelines match, and the same reasoning carries into their
`New-VM.ps1`: the per-VM boot disk is a copy of the qcow2, never a raw
conversion. The `Get-Image.ps1` resize step works on a staging copy of
the downloaded qcow2 and promotes it in the finalize block, so a failed
resize never corrupts the base image.

<a id="429f3d06-0093"></a>

### Hyper-V ISO ACE bloat

Hyper-V base-image ACL bloat from per-VM ACE accumulation.

<a id="429f3d06-0094"></a>

#### Symptom

`New-VM.ps1` fails when attaching the base install image:

```
Add-VMDvdDrive: Failed to add device 'Virtual CD/DVD Disk'.
Hyper-V Virtual Machine Management service Account does not have permission
to open attachment ... Failed to set security info ...
Error: 'Access is denied.' (0x80070005).
... 'The inherited access control list (ACL) or access control entry (ACE)
could not be built.' ('0x8007053C').
```

It appears suddenly on a host that has run many cycles, and **persists
even when PowerShell is elevated (Run as Administrator)**.

<a id="429f3d06-0095"></a>

#### Root cause: the ISO's ACL is full, not a permissions problem

The wording is misleading. This is neither an elevation problem nor a
"grant the service account access" problem -- the file's **DACL has grown
until Windows can no longer add another entry**.

Every time `Add-VMDvdDrive -Path <baseImage>` runs, Hyper-V grants the new
VM read access by **appending an explicit ACE** to the file for that VM's
per-machine virtual account:

- displayed as `NT VIRTUAL MACHINE\<VM-GUID>:(R)` (name form), or
- as a raw SID `S-1-5-83-1-...:(R)` once the VM is gone (both are the same
  `S-1-5-83-1` per-VM account family).

The same grant happens for **any** file a VM attaches -- an ISO via
`Add-VMDvdDrive`, a directly-attached VHDX -- so the pruning helper below
takes an arbitrary file path.

Two facts combine into the failure:

1. **`Remove-VM` never removes that ACE.** Cleanup deletes the VM and its
   per-VM disk, but the grant on the *shared* base image stays.
2. **The base image is downloaded once and reused for every VM.** So those
   ACEs accumulate -- one per VM ever created -- without bound.

A Windows security descriptor's DACL is capped at **~64 KB**. Once the base
image's DACL nears that ceiling, `SetNamedSecurityInfo` can no longer build
a larger ACL for the next VM's ACE -> **`0x8007053C`
(ERROR_INVALID_INHERITANCE_ACL)**. Because that ACE is never written, the
VM worker account can't open the file -> **`0x80070005`
(Access denied)**.

<a id="429f3d06-0096"></a>

##### Why elevation is irrelevant

Your admin token authorizes *you* to call `Add-VMDvdDrive`. The operations
that fail are (1) Hyper-V/VMMS writing the new ACE into the file and (2) the
VM's virtual account (`NT VIRTUAL MACHINE\<guid>`) opening the file -- both
gated by the **file's ACL**, which is full. Elevation can't shrink an
oversized ACL.

<a id="429f3d06-0097"></a>

##### Why only shared base images are affected

| File | Shared? | Accumulates? |
|---|---|---|
| Base install ISO (`...guest.windows.11.iso`, `...ubuntu.server.24/26.iso`) | reused for every VM | **yes** -- one ACE per VM, forever |
| Per-VM seed ISO (`seed.iso` in the per-VM folder) | one VM | no -- at most one ACE |
| Per-VM disk (`<VMName>.vhdx`) | one VM | no |
| Base VHDX (`...guest.amazon.linux.2023.vhdx`, `...caching-proxy-service.vhdx`) | copied per-VM, **never attached directly** | no |

Measured on a developer host after many cycles: the
Windows 11 base ISO already carried **1,412 ACEs** (1,020 raw-SID +
387 name-form per-VM entries) totaling **~56.5 KB / 64 KB**, with **zero**
live VMs on the host. The Linux base ISOs were accumulating the same way.

<a id="429f3d06-0098"></a>

#### Fix

**Prune the per-VM ACEs of VMs that no longer exist**, keeping live VMs
untouched. The shared helper `Remove-OrphanedVMFileAccess` (in
[host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1))
builds the SID set of currently-existing VMs, removes every non-inherited
`S-1-5-83-1-*` ACE that isn't in that set, and writes the trimmed
descriptor with `Set-Acl`. Writing a *smaller* descriptor succeeds even
when the on-disk ACL is already at the limit, so the helper recovers a host
that has already failed. It preserves inherited ACEs, admin/SYSTEM, the
all-VMs group (`S-1-5-83-0`), capability SIDs, and live VMs' own ACEs, so it
is safe to run while other VMs are using the file (the multi-VM pool case).
If it cannot enumerate/translate the live VMs it aborts rather than risk
removing a live VM's access.

Two call sites keep the DACL bounded:

- **(A) Before each attach** -- `New-VM.ps1` for `guest.windows.11`,
  `guest.ubuntu.server.24`, and `guest.ubuntu.server.26` prunes the base
  image immediately before `Add-VMDvdDrive`. By then the VM being created is
  live, so its (not-yet-added) ACE is safe; all earlier VMs' ACEs are gone,
  bounding the DACL to roughly *(live VMs + 1)*.
- **(B) During cleanup** -- `Remove-OrphanedVMFiles.ps1` prunes every kept
  base image on each run (a no-op on the base VHDX images, which accumulate
  nothing), reclaiming ACL space even when no VM is being created. It runs
  before the deletion prompt because it is safe maintenance: it only removes
  access for VMs that no longer exist.

<a id="429f3d06-0099"></a>

##### Manual remediation (already-failing host)

Run elevated. Either prune just the dead VMs (preferred -- keeps live VMs):

```powershell
Import-Module .\host\windows.hyper-v\modules\Yuruna.Host.psm1 -Force
Remove-OrphanedVMFileAccess -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
```

...or, if no VM currently needs the image, reset its ACL entirely (succeeds
even at the limit, because it *replaces* rather than grows the descriptor):

```powershell
icacls "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso" /reset
```

The next `Add-VMDvdDrive` re-adds just the current VM's ACE. Do the same for
the `...ubuntu.server.24/26.iso` base images.

<a id="429f3d06-009a"></a>

##### Diagnostics

```powershell
$iso = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
$acl = Get-Acl $iso
$acl.Access.Count                                        # total ACEs
$acl.GetSecurityDescriptorBinaryForm().Length            # bytes -- approaching 65535 is the cause
```

<a id="429f3d06-009b"></a>

#### Scope

Hyper-V-specific -- it stems from Hyper-V's per-VM virtual-account ACE model.
KVM and macOS/UTM grant guest file access differently and accumulate no
per-VM ACEs on shared images.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.24

Back to [Yuruna](../README.md)
