# Windows 11 guest on macOS UTM host — Nerd-Level Details

See [../../CODE.md](../../CODE.md) for host prerequisites, VM sizing,
and connectivity. macOS counterpart of
[Hyper-V version](../../host.windows.hyper-v/guest.windows.11/). Uses
UTM with the QEMU backend (aarch64, hardware-accelerated via Apple
Hypervisor) to run a Windows 11 ARM64 VM.

## Requirements

| Requirement | Detail |
|---|---|
| **macOS** | 12.0 Monterey or later |
| **Chip**  | Apple M1 or later |
| **UTM**   | v4.0.0 or later |
| **Backend** | QEMU (aarch64, Hypervisor enabled) |

`New-VM.ps1` checks these and exits with an error if unmet.

## 1) Get the image

Prerequisites: `brew install --cask utm`, `brew install powershell qemu`.
Unlike Ubuntu, the Windows 11 ARM64 ISO has no direct download URL.
[`Get-Image.ps1`](./Get-Image.ps1) prints instructions and checks for an
existing ISO in `~/virtual/windows.env/`:

```bash
pwsh ./Get-Image.ps1
```

Three sourcing options:

1. **[UUP dump](https://uupdump.net)** (recommended, free) — build the
   ISO from Windows Update packages. Pick latest ARM64, English (US),
   Windows 11 Pro; run the scripts; save as
   `~/virtual/windows.env/host.macos.utm.guest.windows.11.iso`.
2. **[Windows Insider Program](https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewARM64)**
   — download the ARM64 VHDX and rename it to the path above.
3. **Volume Licensing** (VLSC) — for eligible subscribers.

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) assembles a UTM bundle under
`~/Desktop/Yuruna.VDE/<machinename>/`:

- Copies the ISO as `<vmname>.iso`.
- Creates a 512 GB blank qcow2 disk (`disk.qcow2`).
- Generates an `autounattend.xml` seed ISO labeled `OEMDRV`.
- Writes `config.plist` from
  [`config.plist.template`](./config.plist.template) — QEMU aarch64,
  4 vCPU, 16 GB RAM, UEFI + TPM, NVMe, USB CD, virtio-net-pci,
  intel-hda, clipboard.
- Copies the UTM Guest Tools ISO (`spice.iso`) so SPICE + VirtIO can
  install offline.

```bash
pwsh ./New-VM.ps1                    # default windows11-01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `<hostname>.utm` to import; the installer runs unattended
via autounattend.xml.

### 2.1) Removing installer drives and installing UTM Guest Tools

The Guest Tools ISO contains its own `autounattend.xml`. Setup scans
every attached drive for that file, so attaching `spice.iso` during
installation aborts unattended mode. Attach it only afterwards.

After install the VM has no network — `virtio-net-pci` needs a VirtIO
driver not built into Windows.

1. Stop the VM. In UTM → Drives, remove `<hostname>.iso` and `seed.iso`.
2. Add a drive — Type CD/DVD, Interface USB, Image:
   `~/virtual/windows.env/host.macos.utm.guest.windows.11.spice.iso`.
3. Start the VM; in File Explorer, open the CD drive and run
   **UTM Guest Tools** (SPICE agent + VirtIO network). Allow reboot.
4. Stop the VM; remove the `spice.iso` drive; save and start.

### 2.2) Network configuration

Default is `virtio-net-pci` (needs Guest Tools — see 2.1). Modes via
`-NetworkMode`:

| Mode | Description | When to use |
|---|---|---|
| `Shared` (default) | UTM NAT — VM reaches internet via UTM's router | No Mac VPN |
| `Bridged` | VM connects directly to the LAN | Mac has an active VPN |

VPNs break Shared mode: UTM NAT routes VM traffic through the macOS
stack, and a corporate VPN sends that traffic over the tunnel — Windows
reports "a VPN that cannot be reset." Bridged bypasses the VPN.

```bash
pwsh ./New-VM.ps1 -VMName myhost                                     # Shared
pwsh ./New-VM.ps1 -VMName myhost -NetworkMode Bridged                # Bridged
pwsh ./New-VM.ps1 -VMName myhost -NetworkMode Bridged -BridgeInterface en1
```

Find the active interface: `route get default | grep interface`.

### 2.3) Defaults and activation

Default credentials: `User` / `password`, auto-logon on first boot.
The autounattend sets computer name, locale `en-US`, keyboard `en-US`,
UEFI/GPT, and enables Remote Desktop. Generic Windows 11 Pro key — not
activated until a purchased key or KMS is applied.

## 3) Troubleshooting

### "Cannot import this VM" in UTM

UTM rejected the `config.plist`. Diagnose:

1. Capture the UTM error from the system log **before** double-clicking
   the `.utm`:

   ```bash
   log stream --predicate 'process == "UTM"' --level error
   # Or, after the failure:
   log show --predicate 'process == "UTM"' --style syslog --last 5m 2>/dev/null \
     | grep -i -E 'error|invalid|import|version'
   ```

2. Check version compatibility — UTM validates `ConfigurationVersion`:

   ```bash
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/UTM.app/Contents/Info.plist
   sw_vers -productVersion
   ```

3. Inspect the config (`New-VM.ps1` runs `plutil -lint`):

   ```bash
   cat ~/Desktop/Yuruna.VDE/<mac>/windows11-01.utm/config.plist
   ```

## Known limitations

- ISO must be obtained manually (see 1 above).
- Remove the DVD drives after install.
- VM is unactivated until a key is provided.
- Virtual TPM 2.0 satisfies Windows 11's TPM requirement.
- x86/x64 apps run via Windows' built-in ARM64 emulation.

Back to [[Windows 11 guest (UTM)](README.md)]
