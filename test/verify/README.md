# Verification Screenshots

Screenshots are organized by host+guest combination because the windowing
systems of different hosts (UTM on macOS vs vmconnect on Windows) produce
visually different frames, borders, and rendering.

## Directory structure

```
test/verify/
  expected/                                              # Reference PNGs (committed)
    host.macos.utm.guest.amazon.linux.png
    host.macos.utm.guest.ubuntu.desktop.png
    host.macos.utm.guest.windows.11.png
    host.windows.hyper-v.guest.amazon.linux.png
    host.windows.hyper-v.guest.ubuntu.desktop.png
    host.windows.hyper-v.guest.windows.11.png
  actual/                                                # Runtime captures (git-ignored)
    host.macos.utm.guest.amazon.linux.png
    ...
```

## How Verify-VM uses these screenshots

After the `Test-Start` extension scripts drive the OS installation and the
boot delay elapses, `Verify-VM` captures a screenshot of the VM window and
compares it against the matching file in `expected/` using pixel similarity.
If the similarity is below the configured threshold, the step fails.

The placeholder PNGs shipped with the repo are 1x1 pixel images. Replace
them with real screenshots from your environment to enable verification.

## Capturing reference screenshots

1. Run the full test cycle once to install the OS:
   ```powershell
   pwsh test/Invoke-TestRunner.ps1 -NoGitPull
   ```

2. After the cycle completes, the `actual/` directory will contain the
   captured screenshot for each host+guest pair that ran.

3. Copy the actual capture to `expected/` when it looks correct:
   ```powershell
   cp test/verify/actual/host.windows.hyper-v.guest.windows.11.png test/verify/expected/
   ```

4. Or capture manually:
   - **Hyper-V**: use `Get-VMVideo` or screenshot the vmconnect window.
   - **UTM**: use `screencapture` targeting the UTM window.

## Threshold

The default similarity threshold is 0.85 (85% pixel match). Adjust in
`test-config.json` via `verifyScreenshotThreshold`.
