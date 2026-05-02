# macOS UTM Host Troubleshooting

**Warning:** Instructions are intentionally brief — don't follow them unless you know what you are doing.

## Packages, PATH, and Homebrew issues

- Non-Homebrew packages (e.g. PowerShell) aren't covered by `brew update`/`upgrade`.
- Different install methods can shadow each other via PATH order.
- For most cases, use `brew-doctor-fix.sh`. Occasionally you'll need manual steps like `brew uninstall powershell && brew install powershell`.

## Cleaning Up Old Files

Run `Remove-OrphanedVMFiles.ps1`. It removes anything not tied to an existing VM, including downloaded base images — re-run `Get-Image.ps1` afterward.

## `waitForAndClickButton` loops on "UTM window for `<vm>` not found"

Symptom: the first OCR step (e.g. "Try or Install Ubuntu") matches and
steps succeed, then a later `waitForAndClickButton` warns repeatedly:

```
WARNING: UTM window for 'test-…' not found (CG query returned: not_found).
  Open the VM in UTM.app before using waitForAndClickButton.
DEBUG:   Window capture unavailable — retrying
```

Two possible causes:

1. **Terminal lacks Screen Recording permission.**
   `CGWindowListCopyWindowInfo` strips window titles without this TCC
   grant. Region-capture OCR still works via the AppleScript /
   Accessibility fallback (a different TCC bucket).

2. **UTM's VM window has `NSWindowSharingNone`** (some UTM + Apple
   Virtualization builds). Reachable via the Accessibility API but
   omits `kCGWindowName` from CGWindowList regardless of Screen
   Recording. The harness auto-falls-back to AppleScript bounds —
   debug output shows `CG window query: not_found` then
   `Window bounds query (fallback): <x>,<y>,<w>,<h>`.

Fix for (1):

1. System Settings → Privacy & Security → **Screen Recording** →
   enable your terminal.
2. **Fully quit** the terminal (Cmd-Q) and relaunch — TCC grants don't
   apply to a running process.
3. Re-run the harness.

Case (2) needs no action. If `Window bounds query (fallback)` also
returns `not_found`, UTM's window isn't open: double-click the `.utm`
bundle or click the VM in UTM's sidebar.

## `screencapture -l` returns black, or "UTM window for `<vm>` not found", on a different macOS Space

If you switched Spaces and the runner started failing screen captures
or window-id lookups, verify:

- The window-finder JXA in
  [`Test.Screenshot.psm1`](../../test/modules/Test.Screenshot.psm1)
  uses `kCGWindowListOptionAll` (not `OnScreenOnly`) — only `OptionAll`
  enumerates UTM windows on another Space.
- `Enable-TestAutomation.ps1` flipped `AppleSpacesSwitchOnActivation` to
  `false`:

  ```bash
  defaults read NSGlobalDomain AppleSpacesSwitchOnActivation
  ```

  Returns `1` or "does not exist" → re-run `pwsh ./Enable-TestAutomation.ps1`.

- Right-click UTM in the Dock → Options → Assign To → All Desktops.
  Pins UTM windows on every Space. (Not scripted — Dock plist edits are
  fragile.)

QEMU+VNC guests (e.g. `guest.ubuntu.desktop`) are Space-independent and
need none of the above.

## `Assert-ScreenRecording` false positive — toggle is on but harness refuses to start

System Settings shows the toggle ON, you've fully quit and relaunched,
yet `Invoke-TestRunner.ps1` still rejects with "Screen Recording is
not granted" — the probe is misreporting.

Ground-truth JXA call:

```bash
osascript -l JavaScript -e '
ObjC.import("CoreGraphics");
ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool", []]);
$.CGPreflightScreenCaptureAccess();'
```

If that prints `true`, the grant is in place. Workaround:

```bash
export YURUNA_SKIP_SCREEN_RECORDING_CHECK=1
pwsh test/Invoke-TestRunner.ps1
```

Open an issue with:
- `sw_vers -productVersion`
- `echo $TERM_PROGRAM $TERM_PROGRAM_VERSION`
- The JXA command above
- And:
  ```bash
  osascript -l JavaScript -e '
  ObjC.import("CoreGraphics"); ObjC.import("Foundation");
  $.CFArrayGetCount($.CGWindowListCopyWindowInfo(1, 0));'
  ```

Back to [[macOS UTM Host Setup](README.md)]
