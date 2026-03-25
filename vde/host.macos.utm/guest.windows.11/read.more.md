# Windows 11 guest on macOS UTM host - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the macOS UTM counterpart of the [Hyper-V version](../../host.windows.hyper-v/guest.windows.11/). It uses [UTM](https://mac.getutm.app/) with the QEMU backend (aarch64, hardware-accelerated via Apple Hypervisor) to run a Windows 11 ARM64 VM on Apple Silicon Macs.

### Requirements

| Requirement | Detail |
|---|---|
| **macOS** | 12.0 Monterey or later |
| **Chip** | Apple M1 or later |
| **UTM** | v4.0.0 or later |
| **Backend** | QEMU (aarch64, Hypervisor enabled) |

The `New-VM.ps1` script checks these requirements automatically and exits with an error if they are not met.

### 1.1) Installing UTM

[UTM](https://mac.getutm.app/) is a full-featured virtual machine host for macOS. Install it using [Homebrew](https://brew.sh/):

```bash
brew install --cask utm
brew install powershell
brew install qemu
```

### 1.2) Obtaining the Windows 11 ARM64 image

Unlike Ubuntu, Windows 11 ARM64 ISO cannot be downloaded via a simple direct URL. The script [`Get-Image.ps1`](./Get-Image.ps1) provides instructions and checks for an existing ISO in `~/virtual/windows.env/`.

```bash
pwsh ./Get-Image.ps1
```

**Option 1: UUP dump (recommended, free)**

[UUP dump](https://uupdump.net) builds a Windows 11 ARM64 ISO directly from Windows Update packages. Select the latest ARM64 build, choose English (United States) and Windows 11 Pro, then use the provided scripts to generate the ISO. Save it as `~/virtual/windows.env/host.macos.utm.guest.windows.11.iso`.

**Option 2: Windows Insider Program**

If enrolled in the [Windows Insider Program](https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewARM64), download the Windows 11 ARM64 VHDX and rename it to `host.macos.utm.guest.windows.11.iso` in `~/virtual/windows.env/`.

**Option 3: Volume Licensing**

Windows 11 ARM64 is available through Microsoft Volume Licensing (VLSC) for eligible subscribers.

## 2) Creating the VM

The script [`New-VM.ps1`](./New-VM.ps1) creates a UTM VM bundle under `~/Desktop/Yuruna.VDE/<machinename>/`. It accepts an optional `-VMName` parameter (default: `windows11-01`) and:

- Copies the downloaded Windows 11 ARM64 ISO into the bundle (named `<vmname>.iso`).
- Creates a 512GB blank qcow2 disk (`disk.qcow2`) for installation.
- Generates an `autounattend.xml` seed ISO labeled `OEMDRV` so Windows Setup automatically picks it up and configures the installation with the given hostname.
- Generates a `config.plist` from [`config.plist.template`](./config.plist.template) for a QEMU aarch64 VM (4 CPUs, 16 GB RAM, UEFI + TPM, NVMe disk, USB CD drives, virtio-net-pci network, intel-hda audio, clipboard sharing).
- Copies the UTM Guest Tools ISO (`spice.iso`) into the bundle so SPICE and VirtIO drivers can be installed without a network connection.

```bash
pwsh ./New-VM.ps1
# Or with a custom hostname:
pwsh ./New-VM.ps1 -VMName myhostname
```

After the script completes, double-click `<hostname>.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to import it into UTM. Start the VM and the Windows installer will run automatically via autounattend.xml.

### 2.1) Removing installer drives and installing UTM Guest Tools

> **Why not attach spice.iso before installation?** The UTM Guest Tools ISO contains its own `autounattend.xml`. Windows Setup scans every attached drive for that file, so attaching `spice.iso` during installation causes Setup to abandon the unattended mode and fall back to interactive setup. Attach it only after Windows is fully installed.

After Windows installation completes, the VM has no network because the `virtio-net-pci` adapter requires a VirtIO driver that is not built into Windows.

**Step 1 — Remove the installer drives**

Stop the VM. In UTM, open settings for this VM and go to **Drives**. Remove the two read-only installer drives (`<hostname>.iso` and `seed.iso`).

**Step 2 — Attach the UTM Guest Tools ISO**

Still in **Drives**, click **+** to add a new drive:
- **Type:** CD/DVD (read-only)
- **Interface:** USB
- **Image:** `~/virtual/windows.env/host.macos.utm.guest.windows.11.spice.iso`

Save the settings.

**Step 3 — Install the tools**

Start the VM. Inside Windows, open **File Explorer** and navigate to the CD drive. Run the **UTM Guest Tools** installer. It installs:
- SPICE agent (clipboard sharing, dynamic resolution)
- VirtIO network driver (enables `virtio-net-pci` connectivity)

Allow the installer to reboot the VM. Network will be available after the reboot.

**Step 4 — Remove the tools drive**

Stop the VM again. In UTM settings → **Drives**, remove the `spice.iso` CD drive. Save and start the VM normally.

### 2.2) Network configuration

The VM uses a `virtio-net-pci` adapter for better performance. Windows does not include a built-in VirtIO driver, so network is unavailable until the **UTM Guest Tools** are installed from `spice.iso` (see section 2.1).

Two network modes are available via the `-NetworkMode` parameter:

| Mode | Description | When to use |
|---|---|---|
| `Shared` (default) | UTM NAT — the VM reaches the internet through UTM's built-in virtual router | Normal use; no Mac VPN active |
| `Bridged` | The VM connects directly to the physical LAN and gets its own IP from the router | Mac host has an active VPN that interferes with NAT |

**Why VPNs break Shared mode:** UTM NAT routes VM traffic through the macOS network stack. With an active corporate VPN (Cisco AnyConnect, GlobalProtect, etc.), that traffic goes over the VPN tunnel instead of the physical LAN, causing the VM to lose internet access — reported by Windows Network Diagnostics as "a VPN that cannot be reset." **Bridged mode** connects the virtual adapter directly to the physical interface, bypassing the VPN layer.

```bash
# Default (Shared/NAT):
pwsh ./New-VM.ps1 -VMName myhostname

# Bridged (when Mac has a VPN):
pwsh ./New-VM.ps1 -VMName myhostname -NetworkMode Bridged

# Bridged with explicit interface:
pwsh ./New-VM.ps1 -VMName myhostname -NetworkMode Bridged -BridgeInterface en1
```

To find your Mac's active network interface:
```bash
route get default | grep interface
```

### 2.3) Changing memory allocation

The VM is created with 16 GB of RAM by default. To change the memory allocation:

- **For new VMs:** Edit the `New-VM.ps1` script and replace `16384` in the `__MEMORY_SIZE__` substitution with the desired value in megabytes (e.g., `32768` for 32 GB).
- **For existing VMs:** Open UTM, select the VM, click the settings icon, go to **System**, and change the **Memory** value.

### 2.4) Default credentials and activation

- Default credentials: username `User`, password `password`. Auto-logon is enabled for the first boot only. You will be prompted to change the password on the next login.
- The autounattend sets the computer name, locale (`en-US`), keyboard (`en-US`), UEFI/GPT disk layout, and enables Remote Desktop.
- The installation uses a **generic Windows 11 Pro key** that does not activate Windows. Use a purchased key or KMS activation for a licensed installation.

### 2.5) Testing connectivity

Once the VM is running, find the VM's IP in UTM's network info or in Windows Settings > Network. Connect via **Microsoft Remote Desktop** (available on macOS from the App Store), or via SSH if OpenSSH is enabled in the guest:

```bash
ssh User@<ip-address>
```

## 3) Troubleshooting

### "Cannot import this VM" error in UTM

This error means UTM rejected the `config.plist` generated by `New-VM.ps1`. Possible causes and steps to diagnose:

**Step 1 — Capture the precise UTM error from the system log.**

Run this in a terminal *before* double-clicking the `.utm` bundle, then import and read the output:

```bash
log stream --predicate 'process == "UTM"' --level error
```

Or check recent messages after the failure:

```bash
log show --predicate 'process == "UTM"' --style syslog --last 5m 2>/dev/null \
  | grep -i -E 'error|invalid|import|version'
```

**Step 2 — Check version compatibility.**

UTM validates `ConfigurationVersion` against its own maximum supported version. If UTM is older than the config expects, the import fails. Verify:

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/UTM.app/Contents/Info.plist
sw_vers -productVersion
```

Requirements: UTM v4.0+, macOS 12 Monterey+.

**Step 3 — Inspect the generated config directly.**

`New-VM.ps1` runs `plutil -lint` automatically and exits with an error if the plist is malformed:

```bash
cat ~/Desktop/Yuruna.VDE/<mac>/windows11-01.utm/config.plist
```

## 4) Known limitations

- Windows 11 ARM64 ISO must be obtained manually (see Section 1.2).
- After installation, remove the DVD drives in UTM settings to prevent re-booting into the installer.
- The VM is unactivated unless a valid product key is provided.
- A virtual TPM 2.0 (`TPMDevice`) satisfies Windows 11's TPM requirement.
- x86/x64 applications run via Windows' built-in ARM64 emulation layer (no Rosetta needed).

Back to [[Windows 11 guest on macOS UTM host](README.md)]
