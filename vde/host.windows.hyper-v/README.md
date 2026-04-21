# Windows Hyper-V Host Setup

One-time setup instructions for preparing a Windows host with Hyper-V.

## Quick install (one line)

Open **Windows PowerShell** (or `pwsh`) on a fresh Windows machine and
paste this line:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1$nc" | iex
```

The `$nc` suffix is driven by the `YurunaCacheContent` environment
variable. Leave it unset (or empty) to let caching proxies serve the
stored copy; set it to a unique value — typically a datetime — to force
a fresh fetch. See [docs/caching.md](../../docs/caching.md) for how to
set, persist, and clear the variable on Windows or macOS, and for the
optional Squid cache VM that consumes it.

It installs PowerShell 7, Git, the Windows ADK Deployment Tools
(for `oscdimg.exe`), and Tesseract OCR via `winget`; enables the
**Microsoft-Hyper-V-All** Windows Feature; clones this repository
into `%USERPROFILE%\git\yuruna`; seeds `test\test-config.json` from
the template; and runs
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1)
to disable display timeout and the machine-inactivity lock so
Hyper-V screen captures stay readable. The script is idempotent —
it is safe to run it again to pick up updates.

Consistent with the other Yuruna scripts that need elevation, the
installer prints an up-front banner listing exactly what it needs
Administrator rights for (winget installs, `Enable-WindowsOptionalFeature`,
`powercfg`/registry tweaks inside `Enable-TestAutomation.ps1`)
and — if you started it from a non-elevated shell — self-relaunches
via a **single UAC prompt**. You won't be asked again after that.

After the script finishes, do these steps in order:

1. **Open a new PowerShell window.** The installer ran in a process
   whose `PATH` was patched in-memory, but your original shell still
   has the old environment. A fresh `pwsh` / PowerShell window
   guarantees that `pwsh.exe`, `git.exe`, and `oscdimg.exe` are all
   visible. From here on, prefer `pwsh` over the legacy
   `powershell.exe`.

2. **Restart Windows if Hyper-V was just enabled.** If this is the
   first time `Microsoft-Hyper-V-All` was turned on, the installer
   prints a yellow warning at the end. A reboot is required before
   any Hyper-V cmdlet — and therefore `Invoke-TestRunner.ps1` —
   will work. Skip this step if you already had Hyper-V enabled.

3. **Edit the test config** for your environment:

   ```powershell
   notepad $HOME\git\yuruna\test\test-config.json
   ```

4. **Launch Hyper-V Manager once** so it registers with your user
   profile and surfaces any first-run dialogs:

   ```powershell
   Start-Process virtmgmt.msc
   ```

   This step is *not* automated by the installer: Hyper-V Manager
   personalizes itself per user on first launch, and some
   enterprise-managed machines also require an interactive
   acknowledgement the first time the MMC snap-in loads.

5. **Run the test harness** from the new pwsh window:

   ```powershell
   cd $HOME\git\yuruna\test
   pwsh .\Invoke-TestRunner.ps1
   ```

Want to understand what the installer does, or set things up by
hand? See [read.more.md](read.more.md) for the step-by-step manual
walk-through.

## Optional: Local HTTP cache VM (squid)

The test harness creates and destroys Ubuntu Desktop VMs every cycle.
Each fresh install downloads ~900 MB of packages (kernel, firmware,
desktop tools) from Ubuntu's CDN. When cycles run back-to-back,
Ubuntu's mirrors may return **429 Too Many Requests** for large files
like `linux-firmware`, causing the install to fail.

A small **squid** VM running on the same host eliminates both
problems: the first install populates the local cache, and every
subsequent install pulls the same packages from LAN at disk speed.
Squid replaces the older apt-cacher-ng setup because it caches
every HTTP response (not just .deb URLs), which covers subiquity's
own kernel/firmware fetches — the step that was hitting the 429.

This step is **optional** — the test harness works without it, but
install times drop from ~30 minutes to ~2 minutes on cache hits, and
CDN rate-limit failures stop entirely.

```powershell
# One-time setup (elevated pwsh):
cd $HOME\git\yuruna\vde\host.windows.hyper-v\guest.squid-cache
pwsh .\Get-Image.ps1     # downloads Ubuntu Server cloud image (~600 MB)
pwsh .\New-VM.ps1        # creates 2 GB cache VM, waits for port 3128
```

Once the `squid-cache` VM is running, no further configuration is
needed. The Ubuntu Desktop `New-VM.ps1` automatically detects it and
injects the proxy URL into the autoinstall seed ISO. Stop or delete
the cache VM at any time to revert to direct CDN downloads.

See [docs/caching.md](../../docs/caching.md) for details on how it
works, including the Grafana dashboard, cache tuning, and offline
replay. The test-harness-specific wrappers
(`Start-CachingProxy.ps1`, `Test-CachingProxy.ps1`, and the
`YURUNA_CACHING_PROXY_IP` override consumed by `Invoke-TestRunner.ps1`)
are documented separately in
[test/CachingProxy.md](../../test/CachingProxy.md).

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your
guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
