# macOS UTM host — troubleshooting

**Warning:** Instructions are intentionally brief — don't follow them unless you know what you are doing.

## Packages, PATH, and Homebrew issues

- Non-Homebrew packages (e.g. PowerShell) aren't covered by `brew update`/`upgrade`.
- Different install methods can shadow each other via PATH order.
- For most cases, use `brew-doctor-fix.sh`. Occasionally you'll need manual steps like `brew uninstall powershell && brew install powershell`.

## PowerShell, .NET, and nested `sudo pwsh`

`install/macos.utm.sh` prefers the Homebrew **formula** for PowerShell, which is
framework-dependent on brew's `dotnet` and locates its runtime through
`DOTNET_ROOT`, exported by the wrapper on `PATH`. Any `pwsh` started without
that environment — notably a nested `sudo pwsh`, whose `env_reset` strips it —
fails to find `libhostfxr` and exits **131** before running a line of script.
The error names .NET, never the caller, so it surfaces far from its cause (the
first report was `New-LocalLabStorage.ps1` dying at step 5/8).

Two things make this go away, and the installer does both:
`/etc/dotnet/install_location_$(uname -m)` records the runtime location
machine-wide, read regardless of who starts `pwsh` or with what environment; and
`Get-SudoPwshArgumentList` (`automation/Yuruna.Common.psm1`) adds `-E` on macOS
for every nested launch. To repair a host installed before that:

```
echo "$(brew --prefix dotnet)/libexec" | sudo tee /etc/dotnet/install_location_$(uname -m)
```

`-E` is macOS-only on purpose: Linux ships a self-contained PowerShell that
needs nothing preserved, and a `NOSETENV` sudoers rule there rejects `-E`
outright.

## Do not run the harness scripts under `sudo`

They are built to run unelevated and to elevate individual operations. Under
`sudo` the failure is not (mainly) file ownership — it is that **root has no
Aqua session**: `open -g -a UTM`, `utmctl`, and the `osascript` dialog watchdog
are per-GUI-session, so a root run dies at "UTM did not register `<vm>`" long
before anything mounts. Plain `sudo` also resets `HOME` to `/var/root`, so
bundles, images, the harness SSH key and the vault land in root's home.

Recovery: `sudo chown -R "$USER" ~/yuruna` (the whole tree — removing a
directory needs write permission on its *parent*, and `guest.nosync` is shared
by every builder), then re-run unelevated.

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
to reach the host caching-proxy service and the cycle will fail at the first
`fetch-and-execute` step.

Symptom in the cycle log:

```
cachingProxyIp: 192.168.7.46
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
| `disablesleep` | 1 | Closing a MacBook's lid suspends the host, and every guest running on it, unless this is 1. Also belt-and-suspenders against another subsystem re-enabling idle-sleep on battery. `-a` covers AC + battery + UPS. |
| `powernap` | 0 | Stops dark-wake Mail/Backup cycles. |
| `standby`, `standbydelay*`, `autopoweroff`, `hibernatemode` | 0 | Stops deep sleep / RAM-to-disk transitions that hide UTM. |
| `ttyskeepawake` | 1 | Active tty (SSH, screen capture) keeps the system awake. |
| `tcpkeepalive` | 1 | Sockets stay responsive across idle. |
| `proximitywake` | 0 | Apple-Watch proximity wake can flip lock state. |

Every guard is treated as `OptionalKey` because macOS evolves these
names across major versions (Sonoma split `standbydelay` into
`standbydelaylow`/`standbydelayhigh`; later releases rename or remove
more). The host setup step (`Set-MacHostConditionSet` in
`Test.HostCondition.Mac.psm1`, run by
`host/macos.utm/Enable-TestAutomation.ps1`) applies them all using the
legacy names, which `pmset` accepts as compatibility aliases. The install
script does not apply `pmset` settings; it only primes the sudo cache
for that step. The precheck reads `pmset -g custom` (no sudo) and only invokes
`sudo pmset` if a key is present AND has the wrong value — a missing
key is treated as "macOS no longer surfaces it under that name", not
as a verification failure. This skips an unnecessary sudo prompt when
the values are already correct.

`disablesleep` is the one key exempt from that rule (`AlwaysApply` in
`Get-MacPmsetGuardList`). macOS does not list it in `pmset -g custom`
until it has been written at least once, so on a Mac that never had it
set — precisely the host that needs it — absence would read as "already
1" and `sudo pmset -a disablesleep 1` would never run. Closing the lid
then suspends the host mid-cycle. `Set-MacHostConditionSet` therefore
writes it unconditionally. `Assert-ScreenLock` still skips it when
absent: a Mac with no lid never surfaces the key, and failing the gate
on a setting that host cannot have would block a working desktop test
host. A laptop that drifts back to 0 does list the key, so the gate
still catches it.

## Service VMs come back `suspended` after UTM is quit

Symptom: `yuruna-caching-proxy-service` and `yuruna-stash-service` show
`suspended` in the UTM library (`utmctl status` agrees), and every guest
that consumes them fails — package installs time out against the proxy,
the build cannot upload to the stash. Nothing resumes them; they sit
there until someone presses play.

Root cause: **quitting UTM saves the state of every VM still running.**
UTM's termination handler returns `NSTerminateLater`, writes each running
VM's RAM to disk, and only then lets the app exit. What was `started`
before the quit is `suspended` after it. In the unified log the whole
sequence is visible as a `Handling Quit AppleEvent` /
`applicationShouldTerminate: NSTerminateLater` pair followed seconds
later by `replyToApplicationShouldTerminate:YES` — the gap is the state
being written.

Two things quit UTM, and each has its own guard:

1. **Closing the last window.** UTM's default is to terminate with it.
   `Set-MacHostConditionSet` writes
   `com.utmapp.UTM KeepRunningAfterLastWindowClosed = YES` so the app
   stays resident instead, and `Assert-HostConditionSet` fails a host
   where it drifts back off. UTM reads the key at launch, so a UTM
   already running keeps its old behavior until it is next started.
2. **The framework quitting it on purpose.** `Rename-VM` has to take UTM
   down to edit its Registry plist (`utmctl` has no rename verb), and
   `install/macos.utm.sh` has to take it down to upgrade the cask. The
   rename path captures the running service VMs first and calls
   `Resume-YurunaServiceVM` after the relaunch on every path out; the
   installer refuses to quit at all while any service VM is running
   (`is_service_vm_running`, which also preserves when `utmctl` cannot
   be reached — Apple Events are denied over SSH, and reading that as
   "nothing is running" would quit on exactly the unattended hosts that
   can least afford it).

Side effect worth knowing about: QEMU writes the saved state into the
first qcow2 on its command line, which for these bundles is
`Data/efi_vars.fd` — a 64 MiB UEFI variable store. Each suspend inflates
it by roughly the VM's RAM, and resuming deletes the snapshot without
shrinking the file, so a bundle that has been suspended a few times
carries gigabytes of dead space:

```
qemu-img info -U ~/yuruna/guest.nosync/<vm>.utm/Data/efi_vars.fd
# virtual size: 64 MiB   disk size: 7.55 GiB   <- leaked suspend state
```

Reclaim it with the VM stopped (never while it runs — QEMU holds a write
lock, and `qemu-img info -U` bypasses that lock for *reading* only):

```
qemu-img convert -O qcow2 efi_vars.fd efi_vars.fd.new && mv efi_vars.fd.new efi_vars.fd
```

## A service VM answers, but the dashboard links to a dead address

Symptom: the stash service is up and reachable at its real address, the
Extension hosts row is present, and the deep-link off it goes nowhere.
`runtime/stash-service.json` and `runtime/host.registration.json` disagree
about `stashBaseUrl` / `extensionTargets`.

Root cause is the lease store. macOS files every DHCP lease under the name
the guest sent and never prunes, and a rebuilt guest presents a fresh client
identity — systemd derives its DHCP DUID from a machine-id the rebuild
regenerates — so it is issued a **new** address instead of its predecessor's.
One name therefore accumulates one block per incarnation:

```
grep -c 'name=yuruna-stash-service' /var/db/dhcpd_leases     # 3, on a host rebuilt twice
```

`Get-VMIp` falls back to that file keyed on the guest name, and
`Select-DhcpLeaseIpAddress` picks the largest `lease=` expiry among the
matches. That is right once the live guest has taken its lease, and wrong for
the seconds before it does — the only blocks bearing the name then belong to
guests that no longer exist, and the address handed back parses, sits on-link,
and is dead.

Two things follow from that, and both are guarded:

- **Advertising it.** `Update-StashServiceMarkerAddress` confirms a candidate
  against `/healthz` before publishing it, and keeps polling while it does not
  answer, so the boot-window reply cannot end a 180 s budget on its first tick.
  A budget that expires with nothing confirmed still publishes the last address
  reported — by then the stale window is long past, and refusing a
  correct-but-slow-to-serve address would trade this bug for its opposite — and
  warns that it is unconfirmed.
- **The duplication itself.** `host/macos.utm/Remove-StaleDhcpLease.ps1`
  collapses each name down to its live block. It keeps the largest-expiry block
  of every name, every name carrying only one block, and any block whose
  address still answers ARP or ping — so it is safe to run with guests up.
  `-WhatIf` reports without changing anything; a timestamped backup is written
  first, and a lease file that the DHCP server rewrote mid-run is left alone.

Note that `extensionTargets` in `host.registration.json` is a snapshot taken
when the registration was last written, and the runner writes it *before* it
refreshes the marker (the refresh needs `Get-VMIp`, which is only wired later
in startup). A corrected address therefore reaches the dashboard on the next
cycle, not the current one.

## macOS guest install: embedded Swift VZMacOSInstaller helper

The macOS 26 guest is restored by an embedded Swift helper
(`host/macos.utm/guest.macos.26/New-VM.ps1`) that drives
`VZMacOSInstaller`: it loads the IPSW (`VZMacOSRestoreImage.load(from:)`),
picks `mostFeaturefulSupportedConfiguration` (VZ rejects an install
requesting a hardwareModel the host cannot run), sanity-checks the
requested CPU/memory against
`minimumSupportedCPUCount`/`minimumSupportedMemorySize`, creates a fresh
`VZMacMachineIdentifier`, `VZMacAuxiliaryStorage` at `aux.img` and a
sparse raw `disk.img`, builds a minimal `VZVirtualMachineConfiguration`
(graphics/network are deferred to UTM at runtime via the generated
`config.plist`), restores the IPSW with progress on stderr, and finally
emits `MAC_PLATFORM<TAB>{hardwareModel-base64}<TAB>{machineId-base64}`
for PowerShell to place into the UTM plist. `defer { sema.signal() }`
keeps the wait deterministic in every code path; an unhandled crash
inside the install handler would otherwise hang forever.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.31

Back to [Yuruna](../README.md)
