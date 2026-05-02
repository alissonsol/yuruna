# Ubuntu Server guest on Windows Hyper-V (with `ubuntu-desktop`)

Server-first sister of
[guest.ubuntu.desktop](../guest.ubuntu.desktop/). Boots the Ubuntu
**Server** 24.04 live ISO for autoinstall and adds `ubuntu-desktop`
during the same subiquity pass — first boot lands in GDM.

Use this when the Desktop ISO's `ubuntu-desktop-bootstrap` fails with
`E: Unable to locate package linux-generic[-hwe-24.04]`: the Server ISO
ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`; the Desktop ISO does not.

Cross-host concepts: [../../README.md](../../README.md).

## One-time

From `yuruna\host\windows.hyper-v\guest.ubuntu.server` in
elevated PowerShell:

```powershell
.\Get-Image.ps1
```

## For each VM

```powershell
.\New-VM.ps1                       # default ubuntu-server01
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. Autoinstall is fully unattended
(`interactive-sections: []`). **Install takes ~20–30 min** — subiquity
fetches `ubuntu-desktop` (~2 GB) through squid-cache; keep the
`guest.squid-cache` VM running for dramatically faster rebuilds.

Default `ubuntu` / `password`, change forced on first login. Remove
the DVD drives so the VM boots from disk on next start:

```powershell
Get-VMDvdDrive -VMName 'ubuntu-server01' | Remove-VMDvdDrive
```
