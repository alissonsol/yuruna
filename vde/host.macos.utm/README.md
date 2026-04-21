# macOS UTM Host Setup

One-time setup instructions for preparing a macOS host with UTM.

## Quick install (one line)

Paste this into Terminal on a fresh macOS machine:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos-install.sh)"
```

It installs Xcode Command Line Tools, Homebrew, `git`, PowerShell
(`pwsh`), `tesseract`, and UTM; clones this repository into
`~/git/yuruna`; seeds `test/test-config.json` from the template; and
runs [`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1)
to disable display sleep and the screen saver lock so UTM screen
captures stay readable. The script is idempotent — it is safe to run
it again to pick up updates.

Consistent with the other Yuruna scripts that need elevation, the
installer prints an up-front banner listing exactly what it needs
`sudo` for (Homebrew cask post-install + `pmset` inside
`Enable-TestAutomation.ps1`) and prompts for your macOS password
**once** — the timestamp is then kept alive for the rest of the run.

After the script finishes, do these steps in order:

1. **Make the new tools visible in your current terminal.** The
   installer ran in its own subshell, so the Terminal window where
   you pasted the `curl` command still has no `brew`, `pwsh`, or
   `git` on `PATH`. Either open a new Terminal window, or patch the
   current shell by running the line the installer prints at the end
   — on Apple Silicon this is:

   ```bash
   eval "$(/opt/homebrew/bin/brew shellenv)"
   ```

   (On Intel Macs Homebrew lives at `/usr/local` instead.)

2. **Edit the test config** for your environment:

   ```bash
   $EDITOR ~/git/yuruna/test/test-config.json
   ```

3. **Launch UTM once** so macOS can register it and surface any
   first-run dialogs (network access, file access, etc.):

   ```bash
   open -a UTM
   ```

4. **Grant Accessibility permission to your terminal app.** The
   harness sends keystrokes to UTM VMs through the macOS
   Accessibility API (`AXUIElementPostKeyboardEvent`) so VMs stay
   driven even when they are not the focused window. This step is
   *not* automated by the installer: macOS's TCC (Transparency,
   Consent, and Control) framework deliberately forbids any process
   — even one running as root — from toggling Accessibility on
   behalf of another app. Only a real human click in System Settings
   will do it.

   Go to **System Settings > Privacy & Security > Accessibility**
   and add (or enable) your terminal app: Terminal.app, iTerm2,
   Ghostty, etc.

5. **Run the test harness:**

   ```bash
   cd ~/git/yuruna/test
   pwsh ./Invoke-TestRunner.ps1
   ```

Want to understand what the installer does, or set things up by hand?
See [read.more.md](read.more.md) for the step-by-step manual walk-through.

## Optional: Local HTTP cache VM (squid)

The test harness creates and destroys Ubuntu Desktop VMs every cycle.
Each fresh install downloads ~900 MB of packages (kernel, firmware,
desktop tools) from Ubuntu's CDN. When cycles run back-to-back,
Ubuntu's mirrors may return **429 Too Many Requests** for large files
like `linux-firmware`, causing the install to fail. UTM VMs behind
Apple Virtualization's Shared NAT all egress through the host's
single public IP, which makes the per-source rate limit bite faster
than on Hyper-V — so running a local cache matters more here.

A small **squid** VM running on the same host eliminates both
problems: the first install populates the local cache, and every
subsequent install pulls the same packages from LAN at disk speed.
Squid replaces the older apt-cacher-ng setup because it caches
every HTTP response (not just .deb URLs), which covers subiquity's
own kernel/firmware fetches — the step that was hitting the 429.

This step is **optional** — the test harness works without it, but
install times drop from ~30 minutes to ~2 minutes on cache hits, and
CDN rate-limit failures stop entirely.

```bash
# One-time setup:
cd ~/git/yuruna/vde/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1    # downloads + converts Ubuntu Server cloud image (~600 MB, arm64)
pwsh ./New-VM.ps1        # assembles a UTM bundle; double-click it to register with UTM
```

Once the `squid-cache` VM is running, no further configuration is
needed. The Ubuntu Desktop `New-VM.ps1` auto-detects it via
`utmctl status squid-cache` (falling back to a 192.168.64.0/24:3128
subnet probe) and injects the proxy URL into the autoinstall seed ISO.
Stop the cache VM to revert to direct CDN downloads (a WARNING will
print at the top of the guest-install run).

**Important**: if the cache VM is `started` but port 3128 is unreachable,
the Ubuntu Desktop `New-VM.ps1` now **errors out** (`exit 1`) instead of
silently falling back. This prevents the exact 429 failures the cache
was meant to prevent. Wait for cloud-init to finish (5-15 min on first
boot) or check the VM before retrying.

See [docs/caching.md](../../docs/caching.md) for details — including
the Grafana dashboard at `http://<squid-cache-ip>:3000` (anonymous
Viewer, no login) and the cachemgr.cgi fallback at
`http://<squid-cache-ip>/cgi-bin/cachemgr.cgi`. The test-harness
wrappers (`Start-CachingProxy.ps1`, `Test-CachingProxy.ps1`, and the
`YURUNA_CACHING_PROXY_IP` override) are documented separately in
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
