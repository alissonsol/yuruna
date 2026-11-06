# Ubuntu KVM/libvirt Host Setup

One-time setup for an Ubuntu host running KVM via libvirt. Cross-host
concepts (install-one-liner convention, post-install steps, optional
Squid cache VM, guest workload pattern) live in
[Hosts -- ...](../README.md).

## Quick install (one line)

From a fresh **terminal** on Ubuntu 22.04+:

```
bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
```

(Process substitution rather than `bash -c "$(curl ...)"`. Both reach the
same script, but `bash <(curl ...)` passes it as a real file argument,
sidestepping a stdin/sudo-prompt edge case some Ubuntu terminals trip
on.)

Installs `qemu-system-x86` / `qemu-system-arm` (per arch) + `qemu-utils`,
`libvirt-daemon-system`, `virtinst`, `swtpm`,
`ovmf` (or `qemu-efi-aarch64`), `genisoimage`, `whois`, `git`, `pwsh`,
`tesseract-ocr`, and `virt-manager`; clones the repo to `~/git/yuruna`; enables
`libvirtd` + `virtlogd`; sets the libvirt `default` network to
autostart; adds `$USER` to the `libvirt` and `kvm` groups; seeds
`test/test.config.yml`. Idempotent; prompts for your sudo password
once.

After the group membership change, log out and back in (or
`newgrp libvirt`) before `virsh` and `virt-install` work without sudo.

Disabling display sleep / screen lock for unattended runs is a
separate opt-in step -- run
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) manually after
install, or let `pwsh install/setup.ps1` do it as one step of a guided
[standalone-host or lab setup](../../install/README.md#guided-setup).

## Architecture support

| Guest          | x86_64 | aarch64 |
|----------------|--------|---------|
| Ubuntu Server 24.04 | Yes    | Yes |
| Ubuntu Server 26.04 | Yes    | Yes |
| Amazon Linux 2023   | Yes    | Yes |
| Windows 11     | Yes    | No (use macOS UTM) |

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

## Installing the Ubuntu Host

The really short guide. A self-serving memory!

- Download the latest [Ubuntu Server](https://ubuntu.com/download/server).
- Create a bootable USB, with tools like [Rufus](https://rufus.ie).
- Install Ubuntu Server. Create a "test account" as the local admin, not a real person's account.
- Log in and update.
  - `sudo apt update`
  - `sudo apt upgrade -y`
- Install the desktop.
  - `sudo apt install -y ubuntu-desktop`
  - `sudo reboot now`

Run the update commands again now that the desktop packages are in place.

## Deep diagnostics mode

A host that hard-freezes stops within seconds, loses the last seconds of
what it was writing, logs nothing about the freeze, and stays down until it
is power-cycled. Deep diagnostics mode changes the host so the next freeze
leaves evidence: the kernel panics and reboots instead of hanging where it
can, a hardware watchdog resets it where it cannot, and the minutes before
the freeze survive on disk and on another machine. Use it on a host under
investigation, not on every host (see the caveats).

### What it changes

- **sysctl**: `/etc/sysctl.d/99-zz-yuruna-deep-diagnostics.conf`, named to
  sort last and applied at once as well. Soft lockups, hard lockups and
  oopses panic, with every CPU's backtrace; the NMI watchdog is on;
  `kernel.panic=30` reboots 30 seconds after a panic; `kernel.printk=6 4 1 7`
  sends warnings and notices to the consoles, netconsole among them. A key
  the kernel does not expose is left out, and a drop-in that sorts later and
  sets one of these keys is reported. `kernel.hung_task_panic` stays off:
  slow storage under a VM install trips it on a host that is not hung.
- **pstore**: on a UEFI host, `efi_pstore` is loaded and listed in
  `/etc/modules-load.d/`, with an `/etc/modprobe.d/` option where the kernel
  build disables it, and `systemd-pstore.service` is enabled. A panic's last
  kernel messages are archived to `/var/lib/systemd/pstore` at the next boot.
  Skipped on a legacy BIOS host.
- **watchdog**: `RuntimeWatchdogSec=60s` goes into
  `/etc/systemd/system.conf.d/99-yuruna-deep-diagnostics.conf`, and
  `yuruna-watchdog-driver@<driver>.service` loads the watchdog's driver at
  every boot, because Ubuntu deny-lists these drivers and
  `/etc/modules-load.d/` honors that list. The driver is the one that
  provides the hardware watchdog already registered, found among the loaded
  modules under `kernel/drivers/watchdog/` (such as `i6300esb` in a virtual
  machine, loaded by hand); with none registered, it is the chipset watchdog
  of the CPU vendor (`iTCO_wdt` on Intel, `sp5100_tco` on AMD). A driver
  built into the kernel needs no unit. A host whose processors stop is reset
  about 60 seconds later. Skipped, with the reason, when another process
  holds the device or when the driver that provides it cannot be identified,
  since a watchdog armed now and gone after the next reboot would not catch
  the freeze; never replaced by `softdog`, which runs on the processors that
  freeze and cannot fire.
- **journald**: `Storage=persistent` and `SyncIntervalSec=10s` in
  `/etc/systemd/journald.conf.d/99-yuruna-deep-diagnostics.conf`.
- **rasdaemon**: installed when missing, enabled and started, so
  machine-check, memory and PCIe errors are recorded.
- **netconsole** (with `-NetconsoleTarget <IPv4>[:port]`, port 6666 by
  default): the kernel log goes over UDP to a receiver as it is written,
  though on some kernels not a panic's own lines (see
  [Read the evidence after a freeze](#read-the-evidence-after-a-freeze)).
  `yuruna-netconsole.service` sets the target at boot and
  `/etc/NetworkManager/dispatcher.d/90-yuruna-netconsole` sets it again on
  every address change, because the source address and next-hop MAC address
  are fixed when the target is set.
- **vitals**: `yuruna-vitals.service` writes one `yuruna-vitals:` line to the
  kernel log every 10 seconds: load, available memory, free swap, dirty and
  writeback pages, CPU, memory and I/O pressure, CPU and NVMe temperatures,
  fan speeds and the number of qemu processes.
- **bootEvidence**: `yuruna-boot-evidence.service` runs once per boot, after
  `systemd-pstore` and the journal flush, and writes
  `/var/log/yuruna/deep-diagnostics/boot-<yyyyMMddTHHmmssZ>-<boot id>.txt`
  (directory 0750 and files 0640, group `systemd-journal`; at most about
  2 MB each).

The scripts and units come from [`deep-diagnostics/`](deep-diagnostics/) and
are installed under `/usr/local/lib/yuruna/deep-diagnostics/` and
`/etc/systemd/system/`.

### Enter

```
pwsh host/ubuntu.kvm/Enable-DeepDiagnostics.ps1 -WhatIf
pwsh host/ubuntu.kvm/Enable-DeepDiagnostics.ps1 -NetconsoleTarget 192.168.1.20:6666
```

[`Enable-DeepDiagnostics.ps1`](Enable-DeepDiagnostics.ps1) shows every value
it will change as `key: previous -> new`, asks for the sudo password once,
records every prior value in `/var/lib/yuruna/deep-diagnostics/state.json`
before the first change, then applies each component. A component that
cannot apply on this host is skipped with the reason, and one that fails is
reported while the others still apply. It exits 0 when every component is
applied or skipped, 1 when it refused before changing anything (not Linux,
no systemd, no sudo, a malformed target), and 2 when a component failed.
Running it again changes only what drifted; without `-NetconsoleTarget` it
keeps the target already set.

On a host that runs the test runner, the runner's boot recovery copies each
bundle written since a cycle's last write into that cycle's folder, and it
can read the bundles only as a member of the `systemd-journal` group.
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) adds the runner
account to that group: run it (before or after this script), log out and back
in, and start the test runner from that new session. A runner started from an
older session lacks the group and records the bundles as unreadable.

### Verify

- `echo '<5>yuruna-deep-diagnostics: check' | sudo tee /dev/kmsg` puts a line
  in `journalctl -k -n 5` here and in the receiver's log.
- `journalctl -t yuruna-vitals -n 3` shows a line every 10 seconds. journald
  files each line under the `yuruna-vitals` identifier and keeps only the
  rest as its message, so `-t` finds them and `-g yuruna-vitals` does not.
- `wdctl` and `systemctl show -p WatchdogDevice -p RuntimeWatchdogUSec -p WatchdogLastPingTimestamp`
  show the armed watchdog. Check again after the next reboot: the driver
  loads early in boot and systemd opens the device once it appears.
  `systemctl status 'yuruna-watchdog-driver@*'` names the driver loaded at
  boot, and shows none for a driver built into the kernel.
- `cat /sys/module/pstore/parameters/backend` names a backend.
- `ls /var/log/yuruna/deep-diagnostics/` holds this boot's bundle.

### Read the evidence after a freeze

Start with the newest bundle in `/var/log/yuruna/deep-diagnostics/`. Its
`previousBootId` names the boot that froze, in the same form as `bootId`,
`previousBootLastEntryUtc` is when that boot last wrote to the journal, and
`bootStartUtc` is when this boot began. It holds the previous boot's journal
tail, its kernel warnings, its last ten minutes of vitals and its systemd
(PID 1) watchdog lines, which say whether the boot that froze had the
watchdog armed; this boot's kernel lines about hardware errors and the
watchdog (firmware reports the previous boot's errors through BERT), which
also match startup banners such as `AER: enabled with IRQ` and
`EDAC MC: Ver` that are not errors; the pstore records archived at this
boot; the journal's last 20 boots from `journalctl --list-boots` (Ubuntu
26.04 ships without `last`, whose section then says it is not installed);
`ras-mc-ctl`; and this boot's watchdog state, read when the bundle is
written, which usually comes before systemd arms the device. A panic leaves
its kernel messages in pstore. A freeze that only the watchdog could end
leaves none, and the receiver's log is then the closest record: its last
lines are the last things the host printed. `journalctl -b -1` reads the
rest of the previous boot. Reading the bundles here needs `sudo` or
membership of the `systemd-journal` group; on a runner host, the folder of
the cycle the restart interrupted also holds a copy of each (see
[Enter](#enter)).

Whether a panic's own lines reach the receiver depends on the kernel. Where
netconsole runs as a non-blocking console, which an `N` among the flags of
its line in `/proc/consoles` shows (`netcon_ext0 -W- (E N )` on the 7.0
kernel of Ubuntu 26.04), the kernel sends the panic over netconsole only
when the panic does not reboot. With the 30-second reboot this mode sets,
the receiver's log then ends before the panic, and the panic text is in
pstore instead: `systemd-pstore` archives it at the next boot under
`/var/lib/systemd/pstore/`, where a `dmesg.txt` holds the whole record, and
that boot's bundle holds it in its pstore section. The reboot stays: a host
that comes back on its own is the point of this mode, and pstore keeps the
panic.

### Run the receiver

On another machine that stays on, with pwsh 7 and this repository (Linux,
macOS or Windows):

```
pwsh test/lab/Receive-Netconsole.ps1 -Port 6666
```

[`Receive-Netconsole.ps1`](../../test/lab/Receive-Netconsole.ps1) writes
`netconsole-<sender address>-<yyyyMMdd>.log` under `~/yuruna/netconsole`
(`-OutputDirectory` changes it): one line per record, prefixed with the UTC
time it arrived and flushed to the file at once. Extended netconsole records
show their level, sequence number and time since boot. A log that reaches
`-MaxFileBytes` (64 MB) moves to `.1`, so the newest lines are kept.

That machine's firewall must accept UDP on the port. One that drops it does
so silently on both sides: with ufw active and its default incoming policy
(`Default: deny (incoming)` in `sudo ufw status verbose`), every datagram is
discarded before the receiver sees it, and nothing warns. Open the port to
every sender with `sudo ufw allow 6666/udp`, or to the watched host only
with `sudo ufw allow from <host IPv4> to any port 6666 proto udp`. Then
check that datagrams arrive, before the mode is relied on: on the watched
host, `echo yuruna-check > /dev/udp/<receiver IPv4>/6666` (bash) appears
in the receiver's output as `<host IPv4> <UTC time> yuruna-check` and in
that host's log, and the receiver counts the datagrams it got when it
stops. When nothing appears, `sudo tcpdump -ni any udp port 6666` on the
receiver's machine tells the causes apart: datagrams tcpdump shows and the
receiver does not are dropped by the firewall, and none at all never
reached the machine.

A host that panics sends every CPU's backtrace, and on some kernels the
panic itself (see
[Read the evidence after a freeze](#read-the-evidence-after-a-freeze)), as
one burst, faster than the receiver writes lines, so the receiver asks for a
4 MB socket receive buffer to hold it, and warns at start when the system
grants less. On Linux the stock `net.core.rmem_max` (212992 bytes on most
systems) caps that buffer, and a burst then loses its last lines. Raise it
before starting the receiver, and keep it across reboots:

```
sudo sysctl -w net.core.rmem_max=4194304
echo 'net.core.rmem_max = 4194304' | sudo tee /etc/sysctl.d/90-yuruna-netconsole-receiver.conf
```

The receiver runs in the foreground; to keep it running after the terminal
closes, use
`systemd-run --user --unit yuruna-netconsole-receiver pwsh <repo>/test/lab/Receive-Netconsole.ps1 -Quiet`
on Linux (with `loginctl enable-linger` for that account), `nohup` on macOS,
or a hidden `Start-Process pwsh` on Windows.

### Restore

```
pwsh host/ubuntu.kvm/Disable-DeepDiagnostics.ps1 -WhatIf
pwsh host/ubuntu.kvm/Disable-DeepDiagnostics.ps1
```

[`Disable-DeepDiagnostics.ps1`](Disable-DeepDiagnostics.ps1) reverts what the
state file records, reporting each value as `key: current -> restored`:
runtime sysctl values return to their recorded values, the files, units and
hooks Enable created are removed (a file Enable replaced gets its earlier
content back), the netconsole target is removed, systemd re-executes,
journald restarts, rasdaemon is removed only if Enable installed it, and the
drivers Enable loaded are unloaded once nothing uses them. Evidence bundles
stay unless `-RemoveEvidence` is given, which also removes
`/var/log/yuruna` once nothing else is in it. A step that fails keeps the
state file, and running the script again finishes the restore.

rasdaemon goes with `apt-get purge`, which also deletes its configuration
files and the unit links a plain `apt-get remove` leaves behind (dpkg state
`rc`); when its configuration files were already there before Enable
installed it, it goes with `apt-get remove`, which keeps them as they were.
The packages its install pulled in stay, because other software may use
them: apt marked them as installed automatically, and
`/var/log/apt/history.log` lists them under the `apt-get install -y -q rasdaemon`
entry. To remove them as well, name them:
`sudo apt-get purge <those packages>`. Disable never runs
`apt-get autoremove`, which would also remove every other package apt no
longer needs, older kernels among them.

### Caveats

- A panic, a lockup the kernel detects and a watchdog expiry now reboot the
  host on their own, ending every VM on it and failing the cycle in
  progress. That is the trade: a host that comes back with evidence instead
  of one that stays down without it.
- netconsole sends the kernel log in cleartext UDP across the LAN, and the
  receiver accepts any sender. Use it on a trusted network.
- Notices and warnings now reach the console as well, so a screen attached
  to the host shows more kernel output.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna](../../README.md)
