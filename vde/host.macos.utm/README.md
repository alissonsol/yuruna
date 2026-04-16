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
runs [`test/Set-MacHostConditionSet.ps1`](../../test/Set-MacHostConditionSet.ps1)
to disable display sleep and the screen saver lock so UTM screen
captures stay readable. The script is idempotent — it is safe to run
it again to pick up updates.

Consistent with the other Yuruna scripts that need elevation, the
installer prints an up-front banner listing exactly what it needs
`sudo` for (Homebrew cask post-install + `pmset` inside
`Set-MacHostConditionSet.ps1`) and prompts for your macOS password
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

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your
guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
