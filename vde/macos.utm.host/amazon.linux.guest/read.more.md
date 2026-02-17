# Amazon Linux running in macOS UTM - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the macOS counterpart of the [Hyper-V version](../../windows.hyper-v.host/amazon.linux.guest/). It uses [UTM](https://mac.getutm.app/) to run an Amazon Linux ARM64 VM on Apple Silicon Macs. See [requirements and limitations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html). Instructions here were tested using Amazon Linux 2023 (not Amazon Linux 1 or Amazon Linux 2).

### 1.1) Installing UTM

[UTM](https://mac.getutm.app/) is a full-featured virtual machine host for macOS based on QEMU. Install it using [Homebrew](https://brew.sh/):

```bash
brew install --cask utm
```

The scripts in this folder use PowerShell. Install it with:

```bash
brew install powershell/tap/powershell
```

Additional dependencies:

```bash
brew install qemu
```

- `qemu` provides `qemu-img` for disk image resizing.

### 1.2) Downloading the Amazon Linux image

The script [`Get-Image.ps1`](./Get-Image.ps1) fetches the Amazon Linux 2023 KVM ARM64 qcow2 image from the official CDN. The image is downloaded as a `.qcow2` file and saved to `~/virtual/amazon.linux/`.

```bash
pwsh ./Get-Image.ps1
```

## 2) Creating the VM

The script [`New-VM.ps1`](./New-VM.ps1) creates a UTM VM bundle on your Desktop. It accepts an optional `-VMName` parameter (default: `amazon-linux01`) and:

- Copies the downloaded Amazon Linux qcow2 image into the bundle as the boot disk.
- Resizes the disk to 128GB (thin-provisioned, no extra space used until written).
- Generates a cloud-init `seed.iso` that configures the VM hostname on first boot.
- Generates a `config.plist` from [`config.plist.template`](./config.plist.template) for a QEMU ARM64 VM (4 CPUs, 16 GB RAM, VirtIO disk, UEFI boot, shared networking, sound, clipboard sharing).

```bash
pwsh ./New-VM.ps1
# Or with a custom hostname:
pwsh ./New-VM.ps1 -VMName myhostname
```

After the script completes, double-click `<hostname>.utm` on your Desktop to import it into UTM. Start the VM and cloud-init will apply the configuration on first boot.

### 2.1) Changing memory allocation

The VM is created with 16 GB of RAM by default. To change the memory allocation:

- **For new VMs:** Edit the `New-VM.ps1` script and replace `16384` in the `__MEMORY_SIZE__` substitution with the desired value in megabytes (e.g., `32768` for 32 GB).
- **For existing VMs:** Open UTM, select the VM, click the settings icon, go to **System**, and change the **Memory** value to the desired amount.

- Default credentials: username `ec2-user`, password `amazonlinux`.
- Cloud-init sets the hostname and network configuration from the `seed.iso`.
- After first boot, install the graphical desktop with `sudo dnf groupinstall "Desktop" -y`.

### Key differences from the Hyper-V version

- Amazon Linux provides pre-built qcow2 disk images for KVM (ARM64), so there is no installer ISO step. The VM boots directly from the disk image.
- The `seed.iso` uses cloud-init (not autoinstall) to configure the hostname and default credentials.
- On macOS, `hdiutil makehybrid` replaces `Oscdimg.exe` for creating the seed ISO.
- The disk is resized from the base image size to 128GB using `qemu-img resize`.
