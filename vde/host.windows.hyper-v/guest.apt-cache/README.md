# Apt Cache VM (Hyper-V)

Optional local package cache for Ubuntu Desktop installations.

## What it does

Runs [apt-cacher-ng](https://wiki.debian.org/AptCacherNg) inside a
lightweight Ubuntu Server VM (512 MB RAM, 1 CPU, 50 GB disk). The VM
listens on port 3142 and transparently caches every `.deb` package
that passes through it. The first Ubuntu Desktop install fetches
packages from Ubuntu's CDN as usual; every subsequent install gets
them from the local cache at disk speed.

## Why it helps

- **Speed**: cached installs finish in ~2 minutes instead of ~30.
- **Reliability**: eliminates HTTP 429 (Too Many Requests) failures
  from Ubuntu's CDN, which occur when the test harness creates VMs
  in rapid succession and each one downloads the same ~600 MB
  `linux-firmware` package.

## Setup

Run once from an elevated PowerShell:

```powershell
cd $HOME\git\yuruna\vde\host.windows.hyper-v\guest.apt-cache
pwsh .\Get-Image.ps1
pwsh .\New-VM.ps1
```

`Get-Image.ps1` downloads the Ubuntu Server Noble cloud image
(amd64), converts it from qcow2 to VHDX via `qemu-img`, and resizes
it to 50 GB for cache storage.

`New-VM.ps1` creates a Hyper-V Gen 2 VM named `apt-cache` on the
Default Switch, attaches a cloud-init seed ISO that installs and
enables `apt-cacher-ng`, starts the VM, and waits until port 3142
responds. The script prints the proxy URL when ready.

## How guest VMs use it

The Ubuntu Desktop
[`New-VM.ps1`](../guest.ubuntu.desktop/New-VM.ps1) checks for a
running Hyper-V VM named `apt-cache` at seed-ISO creation time. If
found, it reads the VM's IPv4 address and substitutes
`http://<ip>:3142` into the autoinstall `proxy:` field in the
cloud-init user-data. If the cache VM is not running, the proxy
field stays empty and packages are downloaded directly from Ubuntu's
mirrors (the previous default behavior).

No changes to `test-config.json` or the test sequences are needed.

## Management

The cache VM is independent of the test harness. It is not created
or destroyed by `Invoke-TestRunner.ps1`.

- **Start**: `Start-VM apt-cache`
- **Stop**: `Stop-VM apt-cache`
- **Delete**: `Stop-VM apt-cache -Force; Remove-VM apt-cache -Force`
  then delete the `apt-cache` folder under the Hyper-V VHDX path.
- **Clear cache**: SSH into the VM and run
  `sudo rm -rf /var/cache/apt-cacher-ng/*`

The VM survives host reboots if Hyper-V auto-start is configured
(`Set-VM apt-cache -AutomaticStartAction Start`).

Back to [[Windows Hyper-V Host Setup](../README.md)]
