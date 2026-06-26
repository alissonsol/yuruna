# macOS UTM host — troubleshooting

**Warning:** Instructions are intentionally brief — don't follow them unless you know what you are doing.

## Packages, PATH, and Homebrew issues

- Non-Homebrew packages (e.g. PowerShell) aren't covered by `brew update`/`upgrade`.
- Different install methods can shadow each other via PATH order.
- For most cases, use `brew-doctor-fix.sh`. Occasionally you'll need manual steps like `brew uninstall powershell && brew install powershell`.

## Cleaning Up Old Files

Run `Remove-OrphanedVMFiles.ps1`. It removes per-VM artifacts (bundles, ISOs, etc.) for any VM that no longer exists. Downloaded base images are explicitly KEPT so subsequent `Get-Image.ps1` runs don't re-download them; refresh a base image with the matching `Get-Image.ps1`.

## `tapOn` loops on "UTM window for `<vm>` not found"

Symptom: the first OCR step (e.g. "Try or Install Ubuntu") matches and
steps succeed, then a later `tapOn` warns repeatedly:

```
WARNING: UTM window for 'test-…' not found (CG query returned: not_found).
  Open the VM in UTM.app before using tapOn.
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
  [`Yuruna.Host.psm1`](../host/macos.utm/modules/Yuruna.Host.psm1)
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

QEMU+VNC guests (any guest opting into `-vnc` in `AdditionalArguments`)
are Space-independent and need none of the above.

## `Assert-ScreenRecording` false positive — toggle is on but harness refuses to start

System Settings shows the toggle ON, you've fully quit and relaunched,
yet `Invoke-TestRunner.ps1` still rejects with "Screen Recording is
not granted" — the probe is misreporting.

Ground-truth JXA call:

```
osascript -l JavaScript -e '
ObjC.import("CoreGraphics");
ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool", []]);
$.CGPreflightScreenCaptureAccess();'
```

If that prints `true`, the grant is in place. Workaround:

```
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

## Unrelated UTM VMs split test guests onto a second vmnet-shared bridge

**Limitation:** before starting an `Invoke-TestRunner.ps1` cycle, stop
(or pause) every other UTM VM in the library. Leaving an unrelated VM
running is a known-bad state — cloud-init in the test guests will fail
to reach the host caching proxy and the cycle will fail at the first
`fetch-and-execute` step.

Symptom in the cycle log:

```
cachingProxyIP: 192.168.7.46
guest.<os> Start-VM: PASS ==> IP: 192.168.64.4
Failure pattern matched: 'NONZERO SCRIPT EXIT:' -- aborting wait early
```

OCR of the failing console shows the guest cloud-init retrying:

```
cloud-init[…]: --… (try: N) http://192.168.64.1:8080/yuruna-repo/usr/local/lib/yuruna/fetch-and-execute.sh
cloud-init[…]: Connecting to 192.168.64.1:8080... failed: Connection timed out.
```

Root cause: macOS `vmnet-shared` allocates **one bridge interface per
vmnet "session"**. The first running VM owns `bridge100` (host side
`192.168.64.1/24`); the second is pushed onto `bridge101` (host side
`192.168.65.1/24`). The two bridges do not route between each other,
and yuruna only observes the first bridge at cycle start — so the host
proxy IP it bakes into the test guests' cloud-init seed.iso is the
bridge100 host IP. When the test guests end up on bridge101 (because
an unrelated UTM VM already claimed bridge100), `192.168.64.1:8080`
is unreachable from inside the guest.

Confirm:

```
ifconfig | grep -E '^bridge|inet 192\.168\.6[45]'
# Two bridges present => second one is the trap. Stop the
# unrelated VM and rerun:
utmctl list
utmctl stop <unrelated-vm-name>
```

A persisted snapshot-renamed VM (e.g. `k8s.text-to-sql`) is safe AS
LONG AS IT IS STOPPED. Only **running** UTM VMs occupy a vmnet-shared
session and trigger the split.

## `pmset` guards keep UTM visible across multi-hour runs

Even with `sleep=0`, macOS can blank the display or suspend UTM via
Power Nap (dark wake for Mail/Backup), `standby` (deep sleep),
`autopoweroff` (power-off after N hours of sleep), or
`hibernatemode` (RAM-to-disk). Any of these during a multi-hour cycle
hide the UTM window from CoreGraphics enumeration; the symptom is
`"UTM window for '<vm>' not found. CG: not_found, bounds: not_found"`.

`Set-MacHostConditionSet` therefore asserts an extended set of `pmset`
keys (Test.HostCondition.Mac.psm1, `$pmsetGuards`):

| Key | Want | Why |
|-----|------|-----|
| `disablesleep` | 1 | Belt-and-suspenders against another subsystem re-enabling idle-sleep on battery. `-a` covers AC + battery + UPS. |
| `powernap` | 0 | Stops dark-wake Mail/Backup cycles. |
| `standby`, `standbydelay*`, `autopoweroff`, `hibernatemode` | 0 | Stops deep sleep / RAM-to-disk transitions that hide UTM. |
| `ttyskeepawake` | 1 | Active tty (SSH, screen capture) keeps the system awake. |
| `tcpkeepalive` | 1 | Sockets stay responsive across idle. |
| `proximitywake` | 0 | Apple-Watch proximity wake can flip lock state. |

Every guard is treated as `OptionalKey` because macOS evolves these
names across major versions (Sonoma split `standbydelay` into
`standbydelaylow`/`standbydelayhigh`; later releases rename or remove
more). The in-cycle host condition setup (`Set-MacHostConditionSet`
in `Test.HostCondition.Mac.psm1`) applies them all using the legacy
names, which `pmset` accepts as compatibility aliases. The install
script does not apply `pmset` settings; it only primes the sudo cache
for that step. The precheck reads `pmset -g custom` (no sudo) and only invokes
`sudo pmset` if a key is present AND has the wrong value — a missing
key is treated as "macOS no longer surfaces it under that name", not
as a verification failure. This skips an unnecessary sudo prompt when
the values are already correct.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
