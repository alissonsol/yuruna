# VDE — host and guest concepts

Shared concepts for every `virtual/host.*/` and `virtual/guest.*/` folder.
See [../CODE.md](../CODE.md) for project-wide architecture.

## Folder layout

```
virtual/
├── host.macos.utm/         Host setup for macOS + UTM
├── host.windows.hyper-v/   Host setup for Windows + Hyper-V
│   └── guest.<name>/       Per-guest Get-Image.ps1 + New-VM.ps1 on each host
├── guest.<name>/           Guest-side workload scripts (run inside the VM)
└── docs/                   Per-workload docs (code, k8s, n8n, postgresql, …)
```

Each host folder owns VM provisioning (download image, create VM) for every
supported guest. Each `guest.<name>/` at the root owns workloads that run
inside the guest, independent of which host created it.

## Install one-liner convention

Host setup starts with a single `irm … | iex` (Windows) or
`curl … | bash` (macOS) line. Both read the `YurunaCacheContent` env var —
see [../docs/caching.md](../docs/caching.md) for scope, persistence, and
the optional Squid VM that consumes it.

Both installers are idempotent, request elevation once with an up-front
banner explaining why, and run `Enable-TestAutomation.ps1` to keep the
display on while screenshots are captured.

After the installer finishes:

1. Open a **new** shell so PATH updates are visible.
2. Windows only: reboot if `Microsoft-Hyper-V-All` was just enabled.
3. Edit `test/test-config.json` for your environment.
4. Launch the hypervisor UI once (Hyper-V Manager / UTM) to trigger any
   first-run dialogs.
5. macOS only: grant your terminal app **both** TCC permissions in
   **System Settings → Privacy & Security** — they are separate buckets
   and both are required:
   - **Accessibility** — keystroke injection to UTM VMs.
   - **Screen Recording** — window enumeration
     (`CGWindowListCopyWindowInfo` returns titles only to callers holding
     this grant) and per-window screen capture. Without it,
     `waitForAndClickButton` loops on "UTM window for `<vm>` not found".

   `Enable-TestAutomation.ps1` fires the first-run consent dialog for
   each permission, but macOS's TCC framework forbids automating the
   toggle itself. If you dismiss either dialog, you must toggle the
   switch manually and **fully quit and relaunch the terminal** — TCC
   grants don't apply to the already-running process.
6. Run `pwsh test/Invoke-TestRunner.ps1`.

Host-specific reads that explain what the one-liner does by hand:
[host.macos.utm/read.more.md](host.macos.utm/read.more.md),
[host.windows.hyper-v/read.more.md](host.windows.hyper-v/read.more.md).

## Optional Squid cache VM

Each host has a `guest.squid-cache/` folder that creates a small Ubuntu
Server VM running Squid as an HTTP/HTTPS caching proxy. Run
`Get-Image.ps1` then `New-VM.ps1` once; subsequent guest installs pull
cacheable content (kernels, firmware, `.deb` packages) from LAN instead
of Ubuntu's CDN, dropping install times from ~30 min to ~2 min and
eliminating the `429 Too Many Requests` failures that hit back-to-back
cycles. The harness works without it.

Full setup, monitoring (Grafana on :3000), HTTPS/SSL-bump, and offline
replay are documented once in [../docs/caching.md](../docs/caching.md).
Test-harness-specific wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`) are in
[../test/CachingProxy.md](../test/CachingProxy.md).

## Guest workload pattern

Inside a running guest, workloads are installed by fetching and running
one script each. The fetcher honors `YurunaCacheContent`:

```bash
# Linux guests
/automation/fetch-and-execute.sh virtual/guest.<name>/<name>.<workload>.sh
```

```powershell
# Windows 11 guest (elevated)
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/<workload>.ps1$nc" | iex
```

Available workloads are listed in each [guest.<name>/README.md](.) and
documented per-workload in [docs/](docs/).

## VM sizing and connectivity

Every VM is created with **16 GB RAM, 4 vCPU, 512 GB disk (dynamic/thin)**.
Change for **new VMs**: edit the `New-VM.ps1` you're using (Hyper-V:
replace `16384MB`; UTM: replace `__MEMORY_SIZE__`).

Change for **existing VMs**:

```powershell
# Hyper-V (VM must be stopped):
Stop-VM -Name "<vm>" -Force
Set-VM  -Name "<vm>" -MemoryStartupBytes 32768MB -MemoryMinimumBytes 32768MB -MemoryMaximumBytes 32768MB
Start-VM -Name "<vm>"
```

On UTM: open the VM's settings → **System** → change **Memory**.

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

Per-guest `troubleshooting.md` files cover only guest-specific issues.
Two patterns recur across guests and apply identically everywhere:

- **Time zone** — auto-detected at install; if wrong, fix manually in
  the guest's date/time settings.
- **GUI locks or missing settings panel** — re-run the
  `<name>.<name>.update.sh` workload until clean, then reboot.

Host-side troubleshooting is in
[host.macos.utm/troubleshooting.md](host.macos.utm/troubleshooting.md)
and [host.windows.hyper-v/troubleshooting.md](host.windows.hyper-v/troubleshooting.md).

Back to [[Yuruna](../README.md)]
