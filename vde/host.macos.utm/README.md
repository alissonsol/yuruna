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

After the script finishes:

1. Edit `~/git/yuruna/test/test-config.json` for your environment.
2. Launch UTM once (`open -a UTM`) so it can request any first-run
   permissions, and grant **Accessibility** to your terminal app under
   **System Settings > Privacy & Security > Accessibility** (required
   for the harness to send keystrokes without UTM being focused).
3. Run the test harness:

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
