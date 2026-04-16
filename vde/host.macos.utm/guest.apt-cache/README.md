# Apt Cache VM (macOS UTM)

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

```bash
cd ~/git/yuruna/vde/host.macos.utm/guest.apt-cache
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

`Get-Image.ps1` downloads the Ubuntu Server Noble cloud image
(arm64, qcow2 format) and resizes it to 50 GB for cache storage.

`New-VM.ps1` creates a UTM VM, attaches a cloud-init seed ISO that
installs and enables `apt-cacher-ng`, starts the VM, and waits until
port 3142 responds. The script prints the proxy URL when ready.

> **Note**: The macOS UTM `New-VM.ps1` for the cache VM has not been
> implemented yet (UTM bundle creation requires Apple Virtualization
> framework integration). The `Get-Image.ps1` and `vmconfig/` are
> ready. Contributions welcome, or create the VM manually in UTM
> using the downloaded cloud image and the cloud-init seed files.

## How guest VMs use it

The Ubuntu Desktop
[`New-VM.ps1`](../guest.ubuntu.desktop/New-VM.ps1) probes the
192.168.64.x range (Apple Virtualization shared network) for a
service listening on port 3142 at seed-ISO creation time. If found,
it substitutes `http://<ip>:3142` into the autoinstall `proxy:`
field in the cloud-init user-data. If no cache is detected, the
proxy field stays empty and packages are downloaded directly from
Ubuntu's mirrors (the previous default behavior).

No changes to `test-config.json` or the test sequences are needed.

## Management

The cache VM is independent of the test harness. It is not created
or destroyed by `Invoke-TestRunner.ps1`.

- **Start/Stop**: use the UTM GUI or `utmctl start apt-cache` /
  `utmctl stop apt-cache`
- **Clear cache**: SSH into the VM and run
  `sudo rm -rf /var/cache/apt-cacher-ng/*`

Back to [[macOS UTM Host Setup](../README.md)]
