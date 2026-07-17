# vmconfig topic reference

This file collects the rationale behind every non-trivial line in the
per-guest `vmconfig/` artifacts (`user-data`, `meta-data`,
`autounattend.xml`). The user-data files themselves stay short — each
topic collapses to a single line of the form:

```
# --- REGION: https://yuruna.link/vmconfig#<topic-slug>
```

The fragment resolves to a `### <topic name>` heading in this file.
Slugs follow the standard GitHub Markdown rule: lowercase the heading
text, strip everything that isn't `[a-z0-9_ -]`, then replace spaces
with hyphens. So `### Disable swap` becomes `#disable-swap`.

Topics are written generically (the same explanation applies across
guests on all hosts) and use sub-bullets only where a specific guest or
host needs an exception or addition.

The **caching-proxy** VM has its own cloud-init seed
(`host/vmconfig/caching-proxy.base.user-data`); its per-stanza rationale lives
in [vmconfig.caching-proxy.md](vmconfig.caching-proxy.md). This file covers the
shared *guest* user-data only.

---

## How user-data is rendered

Each `host/<host>/guest.<guest>/New-VM.ps1` merges the shared
`host/vmconfig/<guest>.base.user-data` with its per-host overlay (via
`Build-CloudInitUserData`) and substitutes the following
placeholders before handing the result to `genisoimage` (KVM),
`hdiutil makehybrid` (macos.utm) or to the cloud-init NoCloud
datasource (Hyper-V):

| Placeholder | Source | Notes |
|---|---|---|
| `HOSTNAME_PLACEHOLDER` | `-VMName` parameter | Becomes `identity.hostname` (autoinstall) or the hostname for AL2023 / caching-proxy. |
| `USERNAME_PLACEHOLDER` | `-Username` parameter (per-guest default; see `Test.Ssh\Get-GuestSshUser`) | Account created by autoinstall (Ubuntu Server 24.04) or by the cloud-init `users:` block (AL2023). Same name appears in `passwd --expire`, `sudoers.d/90-yuruna-<user>`, and the GUI sequences. |
| `HASH_PLACEHOLDER` | `Test.VMUtility\ConvertTo-Sha512CryptHash` (wraps `openssl passwd -6 -- <vault-password>`) | SHA-512 (`$6$`) form. Plaintext password comes from `Get-Password -Username <user>` against the per-cycle authentication vault (`test/extension/authentication/`). KVM honours `$YURUNA_GUEST_PASSWORD` as a vault-bypass for ad-hoc dev runs. The `--` separator is LOAD-BEARING -- see "Password hashing: argv leading-dash trap" below. |
| `PLAINTEXT_PASSWORD_PLACEHOLDER` | Same as above (AL2023 path) | Used inside `chpasswd:` for AL2023, where the cloud-init module accepts the plaintext form and force-expires it on first login (chpasswd default `expire: true`). |
| `SSH_AUTHORIZED_KEY_PLACEHOLDER` | `test/status/ssh/yuruna_ed25519.pub` (auto-generated if missing) via `Test.Ssh\Get-YurunaSshPublicKey` | Single ed25519 line; placed under autoinstall.ssh.authorized-keys (Ubuntu) and the cloud-init `users:` block for the test user (AL2023). Same key the post-failure diagnostics path (`Test.Diagnostic\Invoke-RemoteDiagnosticsKeySsh`) authenticates with -- per-host key files would silently break that flow. |
| `APT_PROXY_BLOCK_PLACEHOLDER` | Built per-host by New-VM.ps1 | Multi-line `apt:` block. Substring-replaced (not token-aware), so the literal string MUST NOT appear anywhere else in the file. |
| `CACHING_PROXY_URL_PLACEHOLDER` | `-CachingProxyUrl` parameter | Empty string when no caching-proxy is reachable; the `if [ -n … ]` blocks in user-data are no-ops in that case. |
| `CA_CERT_BASE64_PLACEHOLDER` | macos.utm only — host-fetched CA, base64-embedded | Empty when CA fetch failed; HTTPS apt then bypasses the cache. |
| `YURUNA_HOST_IP_PLACEHOLDER` | Best-effort host IP discovery | Becomes `/etc/yuruna/host.env` and the `yuruna-host` `/etc/hosts` entry. |
| `YURUNA_HOST_PORT_PLACEHOLDER` | `test/test.config.yml:statusService.port` (default 8080) | Same. |

---

## Topic order in user-data

Late-commands (autoinstall) and runcmd (NoCloud) run sequentially. The
order below respects two real dependencies; everything else is a
convention so the three host variants of each guest stay diff-friendly:

1. `wget no_proxy` MUST precede the fetch-and-execute download and the
   timezone wget — both go through `/etc/wgetrc`.
2. `update-grub` MUST come after every `99-yuruna-*.cfg` drop-in.
3. `umount /cdrom` + `losetup -D` MUST be the final late-commands
   (ubuntu.server.24 only — see "Quiet post-install reboot teardown" below).

Recommended order (a guest may legitimately omit topics that don't apply):

1. Apt cache: persist proxy
2. Cap systemd-networkd-wait-online
3. Force first-login password change
4. login session budget
5. Passwordless sudo for harness user
6. Disable swap
7. Disable MOTD
8. hv_balloon denylist *(Hyper-V)*
9. hyperv_fb framebuffer pin *(Hyper-V)*
10. AL2023 framebuffer console *(amazon.linux.2023)*
11. consoleblank kernel cmdline *(KVM ubuntu.server.24)*
12. Console quiet
13. update-grub
14. Console: hold getty until cloud-init signals done *(ubuntu.server.24)*
15. Yuruna host coordinates
16. wget no_proxy
17. Install yuruna lib
18. Timezone via IP geolocation and NTP
19. Quiet post-install reboot teardown *(ubuntu.server.24)*
20. Headless host reboot on framebuffer collapse *(Hyper-V amazon.linux.2023)*

---

## Topics

### apt proxy block

`apt.proxy` (scoped — not top-level `proxy:`) routes only `apt`/`apt-get`
through the local caching-proxy. Scope matters: top-level `proxy:` also
exports `http_proxy`/`https_proxy` into late-commands' env, which
breaks `wget https://...` against proxies that refuse
CONNECT, and would route the host status-service probe through the
cache.

`New-VM.ps1` injects the block at `APT_PROXY_BLOCK_PLACEHOLDER` with
`geoip: false` plus a pinned `primary` mirror; the `proxy:` line is
omitted when no caching-proxy is reachable. Pinning primary + disabling
geoip skips the `geoip.ubuntu.com` HTTPS lookup that otherwise adds
seconds to mirror election.

`primary:` (not curtin's `sources_list:` template): the server squashfs
ships a Deb822 `/etc/apt/sources.list.d/ubuntu.sources` already pointing
at the archive, and curtin's `modifymirrors` rewrites that URI in place —
so one `primary:` pin yields a single fully-rewritten source and apt
fetches indexes once. A `sources_list:` block instead writes a *second*
apt config beside the existing `ubuntu.sources`, doubling every per-suite
index fetch on noble; on resolute's curtin (subiquity snap 7227) it aborts
`subiquity/Mirror/cmd-apt-config` with exit 1 and drops to a recovery shell.

`String.Replace()` is substring-based, so the literal token
`APT_PROXY_BLOCK_PLACEHOLDER` must not appear inside any other comment
or the multi-line YAML will splice into the wrong place and subiquity
will silently drop back to the interactive installer.

### Why server-ISO over desktop-ISO

The cloud-init `autoinstall:` schema requires the Ubuntu **server** ISO;
the desktop ISO uses Ubiquity (or its successor), which has no
equivalent unattended-install mechanism. The test framework drives
provisioning by attaching a NoCloud seed (user-data + meta-data) —
only the server ISO's subiquity reads it. Choosing desktop ISO would
force a GUI-driven first boot that the harness cannot script. The
image selection happens in `Get-Image.ps1` per host.

### chpasswd list schema

*(amazon.linux.2023)*

```
chpasswd:
  list: |
    ec2-user:amazonlinux
```

Stick with the (deprecated) `list:` form rather than the newer
`users:`/`type: text` schema. AL2023's cloud-init parses `list:` cleanly
in plaintext mode; with `users:`/`type: text`, an earlier test cycle
observed the `ec2-user` password not being accepted (cloud-init either
never applied it or stored it in a form `login(1)` couldn't validate),
and the GUI login sequence then loops on a wrong-password dialog. The
deprecation warning is purely cosmetic. Cloud-init's default
`chpasswd.expire: true` applies, so the first-login current/new/retype
dialog still fires.

Do NOT add any spaces after `ec2-user:` — it's part of the password.

### ssh_authorized_keys at top level

*(amazon.linux.2023)*

Top-level `ssh_authorized_keys:` (rather than under a `users:` block)
avoids cloud-init silently merging or dropping the key when the username
matches the distro-default user (`ec2-user`).

### Pass-through user-data: silence SSH fingerprints

*(autoinstall, ubuntu.server.24)*

```
user-data:
  no_ssh_fingerprints: true
  ssh:
    emit_keys_to_console: false
```

Subiquity copies this block to the installed system; cloud-init consumes
it on first boot. Two cloud-init knobs are flipped:

- `no_ssh_fingerprints: true` disables `cc_ssh_authkey_fingerprints`
  (the "Authorized keys for user UBUNTU" ci-info table).
- `ssh.emit_keys_to_console: false` disables `cc_keys_to_console`
  (the `BEGIN SSH HOST KEY FINGERPRINTS` / `BEGIN SSH HOST KEY KEYS`
  blocks dumped via `/dev/kmsg`, which the getty `tty1` echoes
  regardless of login state and races first-boot login).

These are distinct from `autoinstall.ssh` above (subiquity's
installer-side SSH config), which leaves `authorized-keys` / `install-server`
intact.

### LVM sizing policy

```
storage:
  layout:
    name: lvm
    sizing-policy: all
```

`sizing-policy: all` overrides subiquity's server default (`scaled`),
which only allocates ~50 % of the PV to the root LV on <50 G disks and
as little as ~12.5 % on >200 G disks. Without this override the node
ephemeral-storage filesystem on a 64 G qcow2 still landed at ~14 GiB
and tripped kubelet's eviction watermark during the website test.

### Empty interactive-sections

*(autoinstall)*

Disables every interactive step so the install runs fully unattended.
The single "Continue with autoinstall?" confirmation that subiquity
always presents still fires; the GUI test sequence's first step uses
it as a match point.

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
can't OCR — the harness's "wait for ${vmName} login:" step then cannot
tell the install from a hang. `early-commands` run "as soon as the
installer starts, before probing for block and network devices" (Ubuntu
autoinstall reference), so this fires before any 10-min quiet window
could plausibly elapse. KVM-only concern; harmless on Hyper-V's
`hyperv_fb` and Apple Virtualization's virtio-gpu.

### Apt cache: persist proxy

Belt-and-suspenders write of `/target/etc/apt/apt.conf.d/99yuruna-apt-cache`,
so post-install apt-get calls flow through the same caching-proxy subiquity
used for the install. `[ -n "$CACHING_PROXY_URL_PLACEHOLDER" ]` short-circuits when
no cache is configured, so the block is harmless on hosts without one.

The `if`-block also opts into HTTPS caching by trusting the squid CA
and pointing `Acquire::https::Proxy` at the `:3129` ssl-bump listener:

- **Hyper-V / KVM:** the installer fetches the CA in-band via
  `wget http://${CACHE_HOST}/yuruna-squid-ca.crt` — guests reach the
  cache VM directly on the (Default Switch / libvirt 'default') NAT.
  Failure leaves the plain-HTTP proxy in place; HTTPS apt goes direct.
- **macos.utm:** Apple VZ shared-NAT isolates guests from each other,
  so the CA fetch happens on the HOST inside `New-VM.ps1` and the bytes
  arrive base64-embedded via `CA_CERT_BASE64_PLACEHOLDER`. An empty
  placeholder is a graceful no-op: HTTPS apt bypasses the cache (same
  as before ssl-bump existed).

### Enforce proxy egress

Forces ALL public HTTP/HTTPS through the cache. System-wide proxy env
vars (PAM, `/etc/profile.d`, systemd `DefaultEnvironment`) plus an
iptables REJECT on direct 80/443 to catch apps that ignore
`http_proxy` (snap, some Go binaries, browser auto-updaters). RFC1918
and link-local stay reachable so the cache, yuruna-host status server,
and LAN services are not impacted. Conditional on a non-empty
`CACHING_PROXY_URL_PLACEHOLDER` — without a cache the rules are
skipped and traffic flows direct.

The three env-var sinks each serve a different reader: `/etc/environment`
is read by PAM (interactive, cron, ssh sessions); `/etc/profile.d` is
read by login shells (bash + zsh); systemd `DefaultEnvironment` carries
the proxy to daemons started before any user login (cron, snapd, docker,
custom services). Uppercase and lowercase variants are emitted because
some tools only read one form.

`iptables-persistent` loads `/etc/iptables/rules.v4` on boot via
`netfilter-persistent.service` (Before=network-pre.target). The deb's
postinst would prompt "save current rules?"; `debconf-set-selections`
suppresses it. Public 80/443 are blocked with `REJECT
--reject-with icmp-port-unreachable` (not DROP) so the failing app
surfaces a clear error in `dmesg`/`strace`/`journalctl` instead of
hanging on a connect timeout. IPv6 is out of scope: `rules.v6` mirrors
loopback+conntrack so netfilter-persistent has a valid file to load
(otherwise it warns at boot); default IPv6 OUTPUT stays ACCEPT.

### Pin IPv4-only DHCP, refuse IPv6 router advertisements

Anchor: `pin-ipv4-dhcp-refuse-ipv6-ra`

The autoinstall `network:` block in the shared
`host/vmconfig/ubuntu.server.base.user-data` pins
the primary NIC (`match: name: "en*"`) to `dhcp4: true; dhcp6: false;
accept-ra: false`. The glob (rather than a literal `enp0s1`) survives
the 26.04 guest's NIC model switch from `virtio-net-pci` (`enp0s1`)
to `e1000` (`ens1`) — see the comment on the `Network` array in the
guest's `config.plist.template`.

Why this is needed only on the macOS QEMU backend: on
QEMU + `-netdev vmnet-shared`, the host's VMnet stub sends IPv6
router advertisements that `systemd-networkd` interprets as interface
CHANGE events. Subiquity's `NetworkController` treats each CHANGE as
a model update, fires `_send_update`, and never proceeds past network
detection — the install wedges with the framebuffer scrolling:

```
start:  subiquity/Network/_send_update: CHANGE enp0s1
finish: subiquity/Network/_send_update: CHANGE enp0s1
```

forever. The Apple Virtualization backend did not emit these RAs, so
the autoinstall config could omit `network:` and let subiquity auto-
detect; on QEMU the explicit netplan is required. Hyper-V and KVM
guests don't see the same RA stream, so they keep auto-detection.

### Cap systemd-networkd-wait-online

```
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=15
```

Ubuntu 24.04's `networkd-wait-online` defaults to "wait for ALL
interfaces routable, no timeout." `--any --timeout=15` means "ANY
interface routable OR 15s, whichever first" — what the harness needs.
Cloud-init's first-boot run transitively depends on
`network-online.target`, so a stuck wait-online cascades into a
cloud-init failure or minutes of delay before login.

- **Hyper-V Default Switch:** the IPv6 path eventually resolves but
  slowly — visible as
  `Job systemd-networkd-wait-online.service/start running ([TIME] / no limit)`.
- **Apple VZ shared NAT (UTM):** the IPv6 RAs the tracker expects never
  arrive; without the cap the service blocks forever.
- **libvirt 'default' NAT (KVM):** can stall on IPv6 RA waits and
  delay cloud-init via `network-online.target`.

### Password hashing: argv leading-dash trap

*(every host's `New-VM.ps1` that builds `HASH_PLACEHOLDER`)*

`Test.VMUtility\ConvertTo-Sha512CryptHash` is the only sanctioned call
site for hashing the autoinstall / cloud-init password. The helper
invokes:

```
& openssl passwd -6 -- $Plaintext
```

The `--` end-of-options marker is **load-bearing** and must not be
removed:

- `test/extension/authentication/default.psm1` `New-RandomPassword`
  draws from an alphabet that includes `-` (the alphabet covers
  `a-z A-Z 0-9 !@#$%^&*()-_=+`). Roughly one in 72 generated passwords
  starts with `-`. A real failure observed in the wild: vault produced
  `-4aWj*CRw`.
- Without `--`, `openssl passwd -6 -4aWj*CRw` parses `-4aWj*CRw` as an
  unknown option flag, prints `passwd: Use -help for summary` to stderr,
  writes nothing to stdout, and exits non-zero. The cycle
  then writes an EMPTY hash into the cloud-init user-data and the guest
  comes up with no working password -- recoverable only via the
  console.
- With `--`, the dash-prefixed token is unambiguously an operand and
  openssl hashes it correctly.

The same trap applies to any future caller that passes vault plaintext
to a command-line tool. Either:

- Pass plaintext AFTER `--` (e.g. `chpasswd -- "$user:$pw"`, though
  chpasswd's stdin form `echo "$user:$pw" | chpasswd` is preferable
  for the secondary reason of not leaking plaintext into argv); or
- Pass plaintext via stdin (`-stdin` on openssl, the default on
  chpasswd, `SSHPASS`/`-e` on sshpass).

`chpasswd:` `list: |` blocks inside cloud-init `user-data` are NOT
affected: the literal block scalar passes the leading `-` through
intact, and cloud-init then pipes the `user:password` pairs to
`chpasswd` via stdin (where argv parsing is not involved). The AL2023
guest path -- which substitutes plaintext directly into `chpasswd.list:`
rather than computing a hash -- is therefore safe by construction.

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
is substituted by `New-VM.ps1` from the `-Username` parameter
(per-guest default, see `Test.Ssh\Get-GuestSshUser`). Aligns with the cloud-init default for AL2023
(where `chpasswd.expire: true` is default), so the GUI test sequence's
first login fires the same Current/New/Retype dialog across the
supported hosts.

### login session budget

```
sed -i -E "/^[#[:space:]]*LOGIN_TIMEOUT/d" /etc/login.defs && echo "LOGIN_TIMEOUT 180" >> /etc/login.defs
```

`/etc/login.defs LOGIN_TIMEOUT` bounds the entire authentication flow
(initial `Password:` plus Current/New/Retype on an expired account).
At the default 60s, the OCR-driven harness can run out of budget on a
busy host: each prompt costs 1 screenshot + tesseract pass + virsh
send-key chain, accumulating ~10s/step times 4 prompts plus margin.
180s gives ~3× headroom. The `sed` strips any existing entry (commented
or not) before the append, so the change is idempotent.

The `bash -c` wrapper exists because cloud-init's YAML parser treats
the bare regex `/^[#[:space:]]*LOGIN_TIMEOUT/d` as a path; quoting it
inside `bash -c` keeps it as one shell argument.

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

SSH-driven workload calls `/usr/local/lib/yuruna/fetch-and-execute.sh` without a
TTY, so any sudo prompt would block. The drop-in is the standard
`sudoers.d` form (mode 440, owner root:root) so `visudo -c` accepts it.

### Disable swap

```
sed -i '/ swap / s/^/#/' /target/etc/fstab
curtin in-target --target=/target -- systemctl mask swap.target
```

Test VMs run with enough RAM that paging is never desirable — a hung
swap-target during shutdown adds seconds to every cycle. Comment the
fstab entry AND mask `swap.target` so neither the regular boot nor a
late `swapon -a` re-enables it.

### Mask snapd seeded

```
curtin in-target --target=/target -- systemctl mask snapd.seeded.service
```

`snapd.seeded.service` runs `snap wait system seed.loaded` and is
`WantedBy=multi-user.target`, so the getty login prompt cannot appear
until snapd finishes initializing its seed — even when zero snaps are
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

83 % of userspace boot time, gone to a snapd bootstrap that nothing
consumes. Mask only the seed-wait, NOT `snapd.service` / `snapd.socket`
— that keeps on-demand `snap install` available for future workload
scripts via socket activation, while removing the boot-time gate.

### Disable MOTD

```
chmod -x /target/etc/update-motd.d/*
mkdir -p /target/etc/default && test -f /target/etc/default/motd-news && sed -i 's/^ENABLED=1/ENABLED=0/' /target/etc/default/motd-news || echo 'ENABLED=0' > /target/etc/default/motd-news
```

`update-motd.d` scripts and `motd-news` produce many lines of output on
first login (legal banners, "[N] updates can be installed immediately",
canonical advertising). They scroll the OCR harness past the
`Password:` prompt before it can be matched, AND clutter every SSH
session's stdout. Stripping the executable bit on the scripts and
disabling `motd-news` zeroes both.

### hv_balloon denylist

*(Hyper-V)*

```
# /etc/modprobe.d/denylist-hv-balloon.conf
blacklist hv_balloon
```

The synthetic balloon driver only loads under Hyper-V. Its
memory-pressure notifications spam the console and pollute OCR. The
file is inert on KVM/QEMU and macOS UTM where `hv_balloon` never
loads — kept on those hosts purely for cross-host symmetry of the
runcmd / write_files shape.

### hyperv_fb framebuffer pin

*(Hyper-V)*

```
# Ubuntu Server 24.04: /etc/default/grub.d/99-yuruna-hyperv-fb.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} video=hyperv_fb:1024x768"

# AL2023: grubby --update-kernel=ALL --args="video=hyperv_fb:1024x768"
```

When the Windows host's monitor is disconnected, `vmconnect` renders
the Linux guest as a tiny black rectangle in the top-left of an
otherwise white window. The synthetic GPU has no host-display EDID to
negotiate against in headless mode, and `hyperv_fb` falls back to a
near-zero framebuffer size. Pinning a fixed resolution makes the
in-guest driver use it regardless of host display state.

- **Ubuntu Server 24.04:** drop-in under `/etc/default/grub.d/` is additive
  — stacks with the `consoleblank` and `console-quiet` drop-ins
  without clobbering them.
- **AL2023:** AL2023 ships grub2 with no `update-grub` wrapper;
  `grubby` writes `/boot/grub2/grub.cfg` directly and is the AL2023
  idiom. The flag list is deduplicated, so re-running with the same
  arg is a no-op. AL2023 is a pre-built cloud image (no installer
  reboot), so the running kernel still has the OLD cmdline at this
  point — see the "Headless host reboot" topic for the conditional
  reboot that applies the new arg.

### Enable sshd on first boot

*(amazon.linux.2023)*

```
systemctl enable --now sshd || true
```

AL2023's `sshd.service` is installed but not enabled by default in the
cloud image. The harness drives the guest over SSH after the GUI test
sequence completes its login dance, so make sure the service is up
before the test sequence's SSH-side handoff.

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
never sees a `login:` prompt. Three to four steps fix this:

1. Enable + start `getty@tty1` so an `agetty` writes `login:` to
   `/dev/tty1`.
2. `chvt 1` forces fbcon to make `tty1` the active VT (without this
   step fbcon stays on `tty0` and getty's output is buffered but never
   painted).
3. `setterm --blank 0 --powersave off` keeps the framebuffer alive
   DURING the current cloud-init session (one-shot, per-VT escape
   sequence — does NOT survive a getty respawn or a `chvt` away and
   back).
4. *(KVM only)* `grubby --args="consoleblank=0"` makes that no-blank
   policy authoritative at the kernel level for every subsequent boot.
   The default `consoleblank=600` (10 min) is what causes the
   "virt-viewer lost the VNC after a while + OCR stopped working"
   symptom on long test runs.

UTM omits this block entirely because UTM's display window reads the
serial console directly (no framebuffer dependency).

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
`/etc/xdg/autostart/` launches `ptyxis --new-window` for every
graphical login, so a terminal is already on screen by the time the
harness starts its login-and-type dance. `NoDisplay=true` keeps the
launcher out of the applications menu while still honoring the
autostart, and `X-GNOME-Autostart-enabled=true` opts it back in for
GNOME specifically.

### consoleblank kernel cmdline

*(KVM ubuntu.server.24)*

```
# /etc/default/grub.d/99-yuruna-consoleblank.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} consoleblank=0"
```

The kernel default `consoleblank=600` (10 min) blanks the VGA
framebuffer on idle. Symptom: `virt-viewer`'s window stops updating
("looks like the VNC connection dropped"), AND `virsh screenshot` (QMP
screendump — independent of the VNC client) starts producing black
PPMs. Both fall together because the guest's VGA framebuffer is the
source for both. Pin `consoleblank=0` at the kernel cmdline so
EVERY boot (and every VT) inherits no-blank, regardless of whatever
userspace `setterm` calls do or don't survive.

KVM-specific because the Hyper-V variant uses `hyperv_fb:1024x768`
instead and macos.utm's virtio-ramfb doesn't have the same blanking
behavior.

### Console quiet

```
# Ubuntu Server 24.04: /etc/default/grub.d/99-yuruna-console-quiet.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no"

# AL2023: grubby --args="quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no"
```

`passwd`'s `Current password:` prompt parks the cursor at end-of-line
with no trailing newline. On first boot, late-finishing units (snapd
seed, `cloud-final`, etc.) and `KERN_INFO`/`NOTICE` printk messages
keep writing `[ OK ] …` lines to `/dev/console`, overwriting the
parked prompt before the OCR snapshot fires. The harness then sees the
status line and never matches `Current password:`.

- `quiet loglevel=3` raises the printk console threshold from the
  default 4 (`KERN_WARNING`) up to 3 (`KERN_ERR`), suppressing routine
  boot chatter; errors still surface.
- `systemd.show_status=no rd.systemd.show_status=no` mute systemd's
  `[ OK ] Started …` / `[FAILED]` banners in both the initrd and the
  main system.
- `quiet` is typically already in the default cmdline — both
  `update-grub` and `grubby` deduplicate, so the repeat is a no-op.

### Console: bochs-DRM framebuffer safety (KVM)

Anchor: `console-fb-safe`

```
# host/vmconfig/ubuntu.server.kvm.overlay.yml (YURUNA_OVERLAY_GRUB_POST_CONSOLE_QUIET)
- |
  cat > /target/etc/default/grub.d/99-yuruna-fb-safe.cfg << 'GRUBCFG'
  GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} nomodeset console=tty0 console=ttyS0,115200"
  GRUBCFG
```

The KVM bochs-DRM trap class (see
[`feedback_kvm_bochs_drm_resolute_install_trap.md`](memory.md)) lands a
kernel oops in `ovl_iterate_merged` plus `drm_fb_helper_damage_work` CPU
thrash on the resolute live-server installer when the q35+UEFI default
video drives subiquity. The install-phase kernel cannot be reached from
outside (virt-install `--extra-args` needs `--location`, not `--cdrom`),
but pinning `nomodeset` on the *installed* kernel ensures the same trap
can't bite on subsequent boots that the harness drives. `nomodeset`
disables KMS so no DRM driver loads at all; the serial console gives a
diagnostic channel that doesn't depend on the framebuffer.

### update-grub

```
- curtin in-target --target=/target -- update-grub
```

Regenerates `/boot/grub/grub.cfg` so the GRUB drop-ins above
(`99-yuruna-hyperv-fb.cfg`, `99-yuruna-consoleblank.cfg`,
`99-yuruna-console-quiet.cfg`, `99-yuruna-fb-safe.cfg`) take effect on
the post-install reboot.

Must come AFTER all of those drop-ins. AL2023 doesn't ship an
`update-grub` wrapper; `grubby` does the same job inline and is called
per-arg above.

### Console: hold getty until cloud-init signals done

*(ubuntu.server.24)*

```
# /etc/systemd/system/getty@.service.d/override.conf
[Service]
ExecStartPre=-/usr/bin/cloud-init status --wait
```

cloud-init's `running 'modules: final'` / `finished` lifecycle banners
reach the console via `/dev/kmsg` (kernel-style
`[ 44.688245] cloud-init[1065]:` timestamps) unconditionally — there is
no cloud-config knob to silence them, unlike the
`cc_keys_to_console`/`cc_ssh_authkey_fingerprints` pair. On first boot
those banners land AFTER getty has drawn `login:`, so the operator's
typed username and `login(1)`'s subsequent `Password:` prompt get split
across the cloud-init dump and OCR cannot match `Password:`.

`cloud-init status --wait` is the contract cloud-init exposes for
"wait until I'm done"; the leading `-` keeps a degenerate cloud-init
from blocking getty forever. The drop-in lives on the template
(`getty@.service.d/`) so it covers `tty1` plus any other getty the
`systemd-getty-generator` spawns.

`[Unit] After=cloud-final.service` is not enough: it is ordering only
(no `Wants`/`Requires`) and loses a ~5% race on fast
boots: when `getty.target` is reached BEFORE `cloud-final.service`
enters the systemd transaction, the queued `getty@tty1` job is
silently dropped and the VM hangs at "Finished cloud-final.service"
with no login prompt forever (cloud-init issue #2158, lp #1804957).
`status --wait` in `ExecStartPre` avoids the race.

### Yuruna host coordinates

```
mkdir -p /etc/yuruna
cat > /etc/yuruna/host.env <<EOF
YURUNA_HOST_IP=YURUNA_HOST_IP_PLACEHOLDER
YURUNA_HOST_PORT=YURUNA_HOST_PORT_PLACEHOLDER
EOF
grep -q yuruna-host /etc/hosts || echo "YURUNA_HOST_IP_PLACEHOLDER yuruna-host" >> /etc/hosts
```

Two artifacts written for the dev iteration loop:

- `/etc/yuruna/host.env` — guest scripts source this to prefer the
  local status server over GitHub. `Test-YurunaHost.ps1` is the
  in-guest probe that verifies these coordinates are still valid.
- `/etc/hosts` `yuruna-host` entry — gives a stable name that
  survives DHCP renumbering inside the guest's session.

- **Hyper-V Default Switch:** the host IP changes across host reboots.
  Rebuild the guest if `Test-YurunaHost.ps1` fails after a host reboot.
- **libvirt 'default' (KVM):** the gateway is stable at
  `192.168.122.1` — no rebuild needed.

### wget no_proxy

```
cat >> /etc/wgetrc <<EOF
no_proxy = YURUNA_HOST_IP_PLACEHOLDER
EOF
```

Belt-and-braces for the host status-service probe. subiquity's
`apt:proxy` (or AL2023's environment) can leak as `http_proxy` into the
installed system. Without `no_proxy`, an in-guest
`fetch-and-execute.sh` that lacks `--no-proxy` would route the
`/livecheck` probe through the caching-proxy, which cannot reach the
host's NAT address (Hyper-V Default Switch / libvirt default / Apple VZ
shared NAT), and silently fall through to GitHub.

MUST come BEFORE the fetch-and-execute download and the timezone wget
(both rely on the same `/etc/wgetrc`).

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

The two files live in the canonical `/usr/local/lib/yuruna/`
directory on every supported guest:

- `yuruna-retry.sh` — sourced by every guest provisioning script for
  `apt_retry` / `dnf_retry` / `curl_retry`. See
  [Defining yuruna retry lib](https://yuruna.link/network#defining-yuruna-retry-lib).
- `fetch-and-execute.sh` — the harness's invocation point; the
  test-sequence YAMLs call it as
  `/usr/local/lib/yuruna/fetch-and-execute.sh <relative/path/script.sh>`.

Both files are read at seed-build time by the host-side
`New-VM.ps1`, base64-encoded, and embedded as cloud-init
`write_files:` content. The previous wget+wget bootstrap from the
host status server (with a `raw.githubusercontent.com` fallback) is
gone — these two files are now baked into the seed itself, so they
are on disk before any provisioning script runs, with zero network
dependency. Single source of truth: `automation/` in the framework
repo.

### Timezone via IP geolocation and NTP

```
timedatectl set-ntp true
TZ=$(wget -qO - --timeout=5 "http://ip-api.com/line?fields=timezone")
[ -n "$TZ" ] && timedatectl set-timezone "$TZ"
```

Best-effort: failure (no `wget`/`curl`, no network, API down) prints a
`Yuruna => Timezone sync failed` warning to stderr and proceeds with
UTC.

- **ubuntu.server.24:** wget-based.
- **amazon.linux.2023:** curl-based (AL2023 ships curl by default but not
  wget on the cloud image).

### Quiet post-install reboot teardown

*(ubuntu.server.24)*

```
- umount -lf /cdrom || true
- losetup -D || true
```

subiquity holds `/cdrom` (autoinstall ISO) and snapd holds the squashfs
loops; `systemd-shutdown` can't detach them in time and logs cosmetic
`[FAILED] Failed unmounting cdrom` + `Could not detach loopback
/dev/loopN` messages on the install→reboot edge. Running these from
the installer (last late-command, against `/cdrom` NOT
`/target/cdrom`) drops the references before reboot.

`-lf` = lazy-force; both `|| true` because either may be a no-op
already, and a non-zero exit here would fail the entire install.

MUST be the final two late-commands.

### error-commands installer log upload

*(ubuntu.server.24, ubuntu.server.26)*

```
error-commands:
  - <PUT subiquity / curtin / cloud-init logs to the host status server>
```

Runs in the live-installer environment when subiquity aborts the
install. POSTs the curtin / cloud-init / crash files to the host
status server's `/log-upload/` endpoint so the underlying failure
(`apt-get` exit 100, mirror 5xx, hash-sum mismatch) is visible in
the dashboard instead of being lost when the installer drops to a
shell.

- `--no-proxy` / `--noproxy '*'`: bypass any apt proxy that may
  itself be the failure.
- Per-file failures swallowed (`|| true`) so a single bad upload
  does not mask the next.
- `HOST_IP` / `HOST_PORT` baked from `YURUNA_HOST_IP_PLACEHOLDER` /
  `YURUNA_HOST_PORT_PLACEHOLDER`; if either is empty the block
  early-exits 0 (nothing to upload to).

Bucket layout on the status server:
`installer-fail/<hostname>/<UTC-timestamp>/<file>`.

### Headless host reboot on framebuffer collapse

*(Hyper-V amazon.linux.2023)*

```
power_state:
  delay: now
  mode: reboot
  message: "Yuruna: rebooting to apply video=hyperv_fb:1024x768 cmdline (headless host)."
  condition: ["/bin/sh", "-c", "test -f /run/yuruna-needs-reboot"]
```

AL2023 is a pre-built cloud image (no installer reboot), so after the
`grubby --args="video=hyperv_fb:1024x768"` step, the running kernel
still has the OLD cmdline. The very first boot's framebuffer remains
a tiny black rectangle and the OCR-driven test sequence sees nothing.

A runcmd probe earlier in the file checks
`/sys/class/graphics/fb0/virtual_size` — only when the width is
`< 800` does it `touch /run/yuruna-needs-reboot`, so a host with a
monitor attached (which already renders correctly) skips the reboot
and the test sequence's first `login:` capture proceeds on the first
boot.

cloud-init's per-instance lifecycle keeps this from re-firing on
subsequent boots even if the sentinel file were somehow recreated:
`cc_power_state_change` is marked done for the instance after its
first successful run.

---

## Maintenance notes

- New topics: add a `### <topic name>` section here, then in user-data
  emit a single line `# --- REGION: https://yuruna.link/vmconfig#<topic-slug>`.
  Pick heading text whose GitHub-slug is readable — avoid `=`, `/`, `:`,
  `(`, `)` and other punctuation that the slugifier strips silently
  (those make slugs like `console-quiet-quietloglevel3show_statusno`).
- Removed topics: drop the section here AND the one-line reference in
  every guest where it appeared. `grep -r "vmconfig#<slug>" host/`
  to find call sites.
- The recommended order list at the top of this file is the
  authoritative convention; deviating in a specific guest is fine when
  there's a real dependency, but please document why in a one-line
  comment beside the out-of-order step.

---

## Image acquisition and provisioning

Rationale for the `Get-Image.ps1` / `New-VM.ps1` image pipeline that is
shared across hosts but too long to keep inline. (The download
skip-if-same-source guard and the image sentinel's Last-Modified capture
are documented in
[guest-image-setup.md → Skip-if-same-source guard](guest-image-setup.md#skip-if-same-source-guard).)

### macOS UTM qcow2 punchhole alignment

The macOS UTM infra `Get-Image.ps1` scripts (`guest.caching-proxy`,
`guest.stash-service`) keep the final artifact as **qcow2** instead of
converting to raw:

- UTM's QEMU backend boots qcow2 natively, so no raw conversion is needed.
  (Hyper-V converts to VHDX because it cannot boot qcow2 — a genuine
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
conversion. The `Get-Image.ps1` resize step operates on a staging copy of
the downloaded qcow2 and promotes it in the finalize block, so a failed
resize never corrupts the base image.

### Hyper-V ISO ACE bloat

Hyper-V base-image ACL bloat from per-VM ACE accumulation.

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

It appears suddenly on a host that has run many test cycles, and **persists
even when PowerShell is elevated (Run as Administrator)**.

#### Root cause: the ISO's ACL is full, not a permissions problem

The wording is misleading. This is not an elevation problem and not a
"grant the service account access" problem — the file's **DACL has grown
until Windows can no longer add another entry**.

Every time `Add-VMDvdDrive -Path <baseImage>` runs, Hyper-V grants the new
VM read access by **appending an explicit ACE** to the file for that VM's
per-machine virtual account:

- displayed as `NT VIRTUAL MACHINE\<VM-GUID>:(R)` (name form), or
- as a raw SID `S-1-5-83-1-…:(R)` once the VM is gone (both are the same
  `S-1-5-83-1` per-VM account family).

The same grant happens for **any** file a VM attaches — an ISO via
`Add-VMDvdDrive`, a directly-attached VHDX — which is why the pruning
helper below takes an arbitrary file path.

Two facts combine into the failure:

1. **`Remove-VM` never removes that ACE.** Cleanup deletes the VM and its
   per-VM disk, but the grant on the *shared* base image stays.
2. **The base image is downloaded once and reused for every VM.** So those
   ACEs accumulate — one per VM ever created — without bound.

A Windows security descriptor's DACL is capped at **~64 KB**. Once the base
image's DACL nears that ceiling, `SetNamedSecurityInfo` can no longer build
a larger ACL to add the next VM's ACE → **`0x8007053C`
(ERROR_INVALID_INHERITANCE_ACL)**. Because the new VM's ACE never gets
written, the VM worker account can't open the file → **`0x80070005`
(Access denied)**.

##### Why elevation is irrelevant

Your admin token authorizes *you* to call `Add-VMDvdDrive`. The operations
that fail are (1) Hyper-V/VMMS writing the new ACE into the file and (2) the
VM's virtual account (`NT VIRTUAL MACHINE\<guid>`) opening the file — both
gated by the **file's ACL**, which is full. Elevation can't shrink an
oversized ACL.

##### Why only shared base images are affected

| File | Shared? | Accumulates? |
|---|---|---|
| Base install ISO (`…guest.windows.11.iso`, `…ubuntu.server.24/26.iso`) | reused for every VM | **yes** — one ACE per VM, forever |
| Per-VM seed ISO (`seed.iso` in the per-VM folder) | one VM | no — at most one ACE |
| Per-VM disk (`<VMName>.vhdx`) | one VM | no |
| Base VHDX (`…guest.amazon.linux.2023.vhdx`, `…caching-proxy.vhdx`) | copied per-VM, **never attached directly** | no |

A measurement on a working developer host that had run many cycles: the
Windows 11 base ISO already carried **1,412 ACEs** (1,020 raw-SID +
387 name-form per-VM entries) totalling **~56.5 KB / 64 KB**, with **zero**
live VMs on the host. The Linux base ISOs were accumulating the same way.

#### Fix

The mitigation is to **prune the per-VM ACEs of VMs that no longer exist**,
keeping live VMs untouched. The shared helper
`Remove-OrphanedVMFileAccess` (in
[host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1))
does this: it builds the SID set of currently-existing VMs, then removes
every non-inherited `S-1-5-83-1-*` ACE that isn't in that set, and writes the
trimmed descriptor with `Set-Acl`. Writing a *smaller* descriptor succeeds
even when the on-disk ACL is already at the limit, so the helper recovers a
host that has already failed. It preserves inherited ACEs, admin/SYSTEM, the
all-VMs group (`S-1-5-83-0`), capability SIDs, and live VMs' own ACEs — so it
is safe to run while other VMs are using the file (the multi-VM pool case).
If it cannot enumerate/translate the live VMs it aborts rather than risk
removing a live VM's access.

Two call sites keep the DACL bounded:

- **(A) Before each attach** — `New-VM.ps1` for `guest.windows.11`,
  `guest.ubuntu.server.24`, and `guest.ubuntu.server.26` prunes the base
  image immediately before `Add-VMDvdDrive`. By then the VM being created is
  live, so its (not-yet-added) ACE is safe; all earlier VMs' ACEs are gone,
  bounding the DACL to roughly *(live VMs + 1)*.
- **(B) During cleanup** — `Remove-OrphanedVMFiles.ps1` prunes every kept
  base image on each run (no-op on the base VHDX images, which are copied
  per-VM and never attached directly, so they accumulate nothing). This
  reclaims ACL space even when no VM is being created. It runs on every
  invocation, before the deletion prompt, because it is safe maintenance —
  it only removes access for VMs that no longer exist.

##### Manual remediation (already-failing host)

Run elevated. Either prune just the dead VMs (preferred — keeps live VMs):

```powershell
Import-Module .\host\windows.hyper-v\modules\Yuruna.Host.psm1 -Force
Remove-OrphanedVMFileAccess -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
```

…or, if no VM currently needs the image, reset its ACL entirely (succeeds
even at the limit, because it *replaces* rather than grows the descriptor):

```powershell
icacls "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso" /reset
```

The next `Add-VMDvdDrive` re-adds just the current VM's ACE. Do the same for
the `…ubuntu.server.24/26.iso` base images.

##### Diagnostics

```powershell
$iso = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
$acl = Get-Acl $iso
$acl.Access.Count                                        # total ACEs
$acl.GetSecurityDescriptorBinaryForm().Length            # bytes — approaching 65535 is the cause
```

#### Scope

Hyper-V-specific — it stems from Hyper-V's per-VM virtual-account ACE model.
KVM and macOS/UTM grant guest file access differently and do not accumulate
per-VM ACEs on shared images.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
