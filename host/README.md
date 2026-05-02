# Hosts — VM provisioning per hypervisor

Each subfolder owns VM provisioning (image download, VM creation) for
every supported guest on one hypervisor.

- [macOS UTM](macos.utm/README.md)
- [Windows Hyper-V](windows.hyper-v/README.md)

Project-wide architecture: [../CODE.md](../CODE.md). Guest-side
workloads installed inside a running VM: [../guest/README.md](../guest/README.md).

## Folder layout

```
host/
├── macos.utm/         Host setup for macOS + UTM
│   ├── guest.<name>/  Per-guest Get-Image.ps1 + New-VM.ps1
│   └── guest.squid-cache/  Optional caching proxy VM
└── windows.hyper-v/   Host setup for Windows + Hyper-V
    ├── guest.<name>/
    └── guest.squid-cache/
```

The cross-host workload scripts that run **inside** a guest live under
[../guest/](../guest/), separate from these per-host provisioners.

## Install one-liner convention

Host setup starts with a single `irm … | iex` (Windows) or
`curl … | bash` (macOS) line. Both read `YurunaCacheContent` — see
[../docs/caching.md](../docs/caching.md) for scope, persistence, and
the optional Squid VM. Both installers are idempotent, request
elevation once with an up-front banner, and run
`Enable-TestAutomation.ps1` to keep the display on during screenshots.

After the installer finishes:

1. Open a **new** shell so PATH updates apply.
2. Windows only: reboot if `Microsoft-Hyper-V-All` was just enabled.
3. Edit `test/test-config.json` for your environment.
4. Launch the hypervisor UI once (Hyper-V Manager / UTM) to surface
   first-run dialogs.
5. macOS only: grant your terminal app **both** TCC permissions at
   **System Settings → Privacy & Security** (separate buckets; both
   required):
   - **Accessibility** — keystroke injection to UTM VMs.
   - **Screen Recording** — window enumeration (`CGWindowListCopyWindowInfo`
     returns titles only to callers holding this grant) and per-window
     capture. Without it, `waitForAndClickButton` loops on "UTM window
     for `<vm>` not found".

   `Enable-TestAutomation.ps1` fires the consent dialog for each, but
   TCC forbids automating the toggle itself. Dismissed a dialog? Toggle
   manually, then **fully quit and relaunch the terminal** — TCC grants
   don't apply to the running process.
6. Run `pwsh test/Invoke-TestRunner.ps1`.

Manual walk-throughs:
[macos.utm/read.more.md](macos.utm/read.more.md),
[windows.hyper-v/read.more.md](windows.hyper-v/read.more.md).

## Optional Squid cache VM

Each host has a `guest.squid-cache/` folder that creates a small Ubuntu
Server VM running Squid. Run `Get-Image.ps1` then `New-VM.ps1` once;
later guest installs pull cacheable content (kernels, firmware, `.deb`)
from LAN instead of Ubuntu's CDN, cutting install times from ~30 min to
~2 min and eliminating the `429 Too Many Requests` failures that hit
back-to-back cycles. The harness works without it.

Full setup, monitoring (Grafana on :3000), HTTPS/SSL-bump, and offline
replay live in [../docs/caching.md](../docs/caching.md). Test-harness
wrappers (`Start-CachingProxy.ps1`, `Test-CachingProxy.ps1`,
`YURUNA_CACHING_PROXY_IP`): [../test/CachingProxy.md](../test/CachingProxy.md).

## VM sizing and connectivity

Every VM is **16 GB RAM, 4 vCPU, 512 GB disk (dynamic/thin)**. Change
for **new VMs**: edit `New-VM.ps1` (Hyper-V: replace `16384MB`; UTM:
replace `__MEMORY_SIZE__`).

Existing VMs:

```powershell
# Hyper-V (stop first):
Stop-VM -Name "<vm>" -Force
Set-VM  -Name "<vm>" -MemoryStartupBytes 32768MB -MemoryMinimumBytes 32768MB -MemoryMaximumBytes 32768MB
Start-VM -Name "<vm>"
```

UTM: VM settings → **System** → **Memory**.

Find the guest IP:

```powershell
# Hyper-V:
Get-VM -Name "<vm>" | Select-Object -ExpandProperty NetworkAdapters | Select IPAddresses
```

```bash
# UTM console shows `eth0: <ip>` at the login prompt; or
awk -F'[ =]' '/name=<vm>/{f=1} f && /ip_address/{print $NF; exit}' /var/db/dhcpd_leases
```

Then `ssh <user>@<ip>` (Linux) or `mstsc /v:<ip>` / `ssh User@<ip>`
(Windows).

## Troubleshooting themes

Per-guest `troubleshooting.md` files cover guest-specific issues. Two
patterns recur across guests:

- **Time zone** — auto-detected at install; if wrong, fix in the
  guest's date/time settings.
- **GUI locks or missing settings panel** — re-run the
  `<name>.<name>.update.sh` workload until clean, then reboot.

Host-side troubleshooting:
[macos.utm/troubleshooting.md](macos.utm/troubleshooting.md),
[windows.hyper-v/troubleshooting.md](windows.hyper-v/troubleshooting.md).

Back to [[Yuruna](../README.md)]
