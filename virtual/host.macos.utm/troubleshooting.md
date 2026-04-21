# macOS UTM Host Troubleshooting

**Warning:** This is not a section for everyone. Instructions are intentionally brief — don't follow them unless you know what you are doing!

## Packages, PATH, and Homebrew issues

- Packages not installed via `Homebrew` (e.g. PowerShell) won't be updated by `brew update` / `brew upgrade` cycles.
- Packages installed by different methods can shadow each other via PATH order ([DLL hell](https://en.wikipedia.org/wiki/DLL_hell) has company!).
- For most of those situations, use `brew-doctor-fix.sh`.
- Occasionally you may still need manual steps, e.g. `brew uninstall powershell` followed by `brew install powershell`.

## Cleaning Up Old Files

- Run `Remove-OrphanedVMFiles.ps1`.
- Note: this removes any files not associated with existing VMs, including downloaded base images — you would then need to re-run the relevant `Get-Image.ps1` scripts.

## `waitForAndClickButton` loops on "UTM window for `<vm>` not found"

Symptom: the first OCR step (e.g. "Try or Install Ubuntu") matches and
steps succeed, then a later `waitForAndClickButton` warns repeatedly:

```
WARNING: UTM window for 'test-…' not found (CG query returned: not_found).
  Open the VM in UTM.app before using waitForAndClickButton.
DEBUG:   Window capture unavailable — retrying
```

Cause: the terminal running `pwsh` is missing **Screen Recording**
permission. `CGWindowListCopyWindowInfo` strips window titles when the
caller lacks this TCC grant, so the harness can't match UTM's per-VM
window by name. Region screenshots (OCR) still work, which is why
earlier steps succeed.

Fix:

1. System Settings → Privacy & Security → **Screen Recording** →
   enable your terminal (Terminal.app, iTerm2, Ghostty, etc.).
2. **Fully quit** the terminal (Cmd-Q — not just close the window)
   and relaunch. TCC grants don't apply to a running process.
3. Re-run the harness.

## `Assert-ScreenRecording` false positive — toggle IS on but harness refuses to start

If System Settings shows the toggle ON for your terminal, you've
fully quit and relaunched (or rebooted), and
`Invoke-TestRunner.ps1` still refuses to start with "Screen Recording
is not granted", the probe itself is misreporting state.

Confirm with the ground-truth JXA call:

```bash
osascript -l JavaScript -e '
ObjC.import("CoreGraphics");
ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool", []]);
$.CGPreflightScreenCaptureAccess();'
```

If that prints `true`, the grant is in place and the harness probe
is wrong for your macOS version. As a temporary workaround, set:

```bash
export YURUNA_SKIP_SCREEN_RECORDING_CHECK=1
pwsh test/Invoke-TestRunner.ps1
```

Then please open an issue with:
- Output of `sw_vers -productVersion`
- Output of `echo $TERM_PROGRAM $TERM_PROGRAM_VERSION`
- Output of the JXA command above
- Output of
  ```bash
  osascript -l JavaScript -e '
  ObjC.import("CoreGraphics"); ObjC.import("Foundation");
  var n = $.CFArrayGetCount($.CGWindowListCopyWindowInfo(1, 0));
  n;'
  ```

Back to [[macOS UTM Host Setup](README.md)]
