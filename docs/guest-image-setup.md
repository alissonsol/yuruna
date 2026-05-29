# Guest image setup — common pattern

> Shared lifecycle that every `host/<HOST>/guest.<GUEST>/` folder
> follows. Per-host READMEs document only the deltas (paths, package
> manager, ISO source, host-specific verification steps).

Placeholders used in this document:

| Placeholder    | Meaning                                                   | Examples                                          |
|----------------|-----------------------------------------------------------|---------------------------------------------------|
| `<HOST>`       | The host platform                                         | `windows.hyper-v`, `macos.utm`, `ubuntu.kvm`      |
| `<GUEST>`      | The guest identity used by the planner                    | `ubuntu.server.24`, `amazon.linux.2023`, ...      |
| `<CODENAME>`   | OS release codename for Ubuntu guests                     | `noble` (24.04), `resolute` (26.04)               |
| `<USERNAME>`   | The per-guest test user                                   | `yuuser24`, `yuuser26`, `yauser1`                 |

## Lifecycle stages

The same six stages apply across hosts. A per-host README that
diverges from this list is documenting host-specific knowledge — keep
that content; don't duplicate the common stages.

### 1. Download / refresh the image

```
pwsh ./Get-Image.ps1                # macOS UTM, Ubuntu KVM
.\Get-Image.ps1                     # Windows Hyper-V (elevated PowerShell)
```

`Get-Image.ps1` is idempotent — it skips the download when the local
copy already matches the upstream metadata (size + timestamp). The
script writes into `~/yuruna/image/<GUEST>.env/` (POSIX) or
`%USERPROFILE%\yuruna\image\<GUEST>.env\` (Windows). Architecture
(amd64 / arm64) is picked from the host automatically — there is no
flag to force a cross-architecture image.

Image source by host:

- **Hyper-V** — vendor ISO (Ubuntu live-server, Windows 11 media)
  pulled directly. Some publishers gate the download behind a
  short-lived URL; `Get-Image.ps1` prints manual fallback steps when
  the automated fetch is blocked.
- **macOS UTM** — same as Hyper-V for ISO-based guests. macOS guests
  use `.ipsw` (queried via the Virtualization framework rather than a
  stable URL).
- **Ubuntu KVM** — qcow2 cloud image for amazon.linux.2023; live-server
  ISO for ubuntu.server.\<N\>. The script resizes the qcow2 to the
  target size with `qemu-img resize`.

### 2. Checksum verification

When the upstream publisher provides a `SHA256SUMS` (or equivalent)
file alongside the image, `Get-Image.ps1` downloads it and verifies
the local file before declaring success. Failures surface as a
script-level error, not a silent retry. If the publisher does not
publish a checksum (Apple IPSWs, some Windows ISO mirrors), the
script falls back to size + timestamp and prints a one-line warning.

### 3. Conversion (Hyper-V only, for cloud images)

Hyper-V requires VHDX. The caching-proxy and any other cloud-image-based
Hyper-V guests run `qemu-img convert ... -O vhdx` and then clear the
NTFS-sparse flag that qemu-img leaves on the output (otherwise
`Resize-VHD` fails with `0xC03A001A`). This step is encapsulated in
`Get-Image.ps1` for the hosts that need it.

### 4. Create / install the VM

```
pwsh ./New-VM.ps1                          # default VM name from the planner
pwsh ./New-VM.ps1 -VMName myhost           # custom VM name
pwsh ./New-VM.ps1 -CachingProxyUrl http://192.168.122.10:3128
```

What `New-VM.ps1` does is host-dependent:

- **virt-install (KVM)** — renders `vmconfig/user-data` +
  `vmconfig/meta-data` with the per-cycle SSH key
  (`test/status/ssh/yuruna_ed25519`, auto-generated when missing),
  builds a CIDATA seed ISO with `genisoimage`, allocates an empty
  qcow2 install target, and runs `virt-install` against
  `qemu:///system` with the live ISO + seed CD attached.
- **New-VM (Hyper-V)** — calls `New-VM` / `Set-VMProcessor` /
  `Add-VMHardDiskDrive` directly. Contract names (`New-VM`,
  `Start-VM`, `Stop-VM`, `Remove-VM`) collide with the Hyper-V
  cmdlets; the Yuruna.Host module qualifies them with `Hyper-V\` to
  bypass the collision.
- **UTM (macOS)** — writes a `.utm` bundle in
  `~/yuruna/guest.nosync/` that the operator double-clicks in Finder
  to import. The bundle ships the same cloud-init seed content as
  the KVM path.

### 5. Unattended install + first boot

The install method depends on the guest family:

- **Ubuntu live-server** — subiquity autoinstall driven by the CIDATA
  seed, fully unattended (`interactive-sections: []`). After install
  the VM reboots and lands at a text-mode login.
- **Amazon Linux 2023** — boots straight from the cloud image; first
  boot triggers cloud-init, which lays down `<USERNAME>` on top of
  the default `ec2-user` and forces a password rotation.
- **Windows 11** — installer runs unattended via `autounattend.xml`
  (~15 min). First login auto-logs as `User`/`password`; the change
  is forced on next login.

### 6. SSH ready / first-cycle readiness

The harness considers a guest ready when:

1. The VM is in the `running` state (per the host driver's
   `Get-VMState`, polled by `Wait-VMRunning`).
2. The guest's IP is discoverable (`Wait-VMIp` / `Get-VMIp`; KVP on
   Hyper-V — note that an External vSwitch puts a third party in
   charge of DHCP, so KVP can be 5-15 min late and an active-probe
   of the subnet may be needed; `virsh domifaddr` on KVM).
3. SSH completes a real handshake — `Wait-SshReady`, not just TCP/22
   (a TCP-only check races a half-up sshd in the moments after a
   guest reboot).

For ad-hoc verification:

```
# Hyper-V
Get-VM -Name <VMName>
# KVM
virsh -c qemu:///system list
virsh -c qemu:///system domifaddr <VMName>
ssh -i ../../../test/status/ssh/yuruna_ed25519 <USERNAME>@<ip>
# UTM (after the .utm bundle is imported)
# IP via `arp -a` or the guest's serial console.
```

## Keeping a guest patched: `<GUEST>.update.sh`

Each `guest/<GUEST>/` folder ships a `<GUEST>.update.sh` script (e.g.
`ubuntu.server.24.update.sh`, `amazon.linux.2023.update.sh`,
`ubuntu.server.26.update.sh`). These run the guest's native package
manager non-interactively, clear stale state, and reboot if the
kernel was bumped. Two ways to invoke them:

- **Inside a cycle** — the framework's workload sequences call the
  matching update script automatically as part of the per-guest
  workload phase.
- **Ad hoc** — to refresh a long-running VM without a full cycle:

  ```
  ssh -i ../../../test/status/ssh/yuruna_ed25519 <USERNAME>@<ip> \
      'bash -s' < ../../guest/<GUEST>/<GUEST>.update.sh
  ```

The scripts are idempotent — they're safe to re-run when a GUI lock
or settings-panel glitch needs a clean reboot to clear (the symptom
described in [host/README.md](../host/README.md#troubleshooting-themes)).

## Credentials

The per-cycle test password lives in the authentication extension's
vault at `test/status/extension/authentication/vault.yml` (code under
[`test/extension/authentication/`](../test/extension/authentication/)).
The autoinstall / cloud-init configuration marks the password
**expired**, so the first interactive login asks for current / new /
retype before yielding a shell. The harness's `start.guest.*.yml`
sequence drives that rotation against the OS prompt.

For ad-hoc runs outside a cycle, set `$env:YURUNA_GUEST_PASSWORD` to
a known plaintext before `New-VM.ps1` to bypass the vault.

## Caching proxy

When a `guest.caching-proxy` VM is running on any host, pass its IP via
`-CachingProxyUrl` to `New-VM.ps1`. Cloud-init / autoinstall picks the
URL up and points apt / dnf at it for the install, which is
dramatically faster than hitting upstream mirrors on every rebuild.
See [`docs/caching-proxy.md`](caching-proxy.md) and
[`docs/caching.md`](caching.md).

## Cleanup

Removing a guest is the inverse of stage 4:

```
# Hyper-V
Stop-VM -Name <VMName> -Force; Remove-VM -Name <VMName> -Force
Remove-Item "~\yuruna\vms\<VMName>" -Recurse -Force
# KVM
virsh -c qemu:///system destroy <VMName>
virsh -c qemu:///system undefine <VMName> --remove-all-storage
# UTM
# Right-click the VM in UTM -> Delete; then remove the bundle under
# ~/yuruna/guest.nosync/.
```

The image cache under `~/yuruna/image/<GUEST>.env/` is preserved
across deletes so the next `New-VM.ps1` doesn't have to re-download.

---

Copyright (c) 2019-2026 by Alisson Sol et al.
