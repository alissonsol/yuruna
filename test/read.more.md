# Test Runner — Nerd-Level Details

The crisp version lives in [Yuruna Test ...](README.md); this file holds the
full configuration table, sequence development, screenshot training,
status server details, and SSH-server controls.

## Configuration keys

`test.config.yml` uses a nested layout — related settings are grouped
under `vmStart`, `vmImage`, `vmCommunication`, `repositories`, and
`testCycle` nodes. The dotted paths below are the YAML node + key.

| Key | Default | Description |
|-----|---------|-------------|
| `guestSequence` | _required_ | Array of guest keys; each must correspond to `host/<short-host>/<guestKey>/` |
| `testCycle.cycleDelaySeconds` | `30` | Pause between cycles |
| `testCycle.shouldStopOnFailure` | `false` | `true` = stop on first failure and preserve VM; `false` = clean up and continue. Failure artifacts always copied to `status/log/` |
| `testCycle.recentDisplayCount` | `30` | Runs kept in status history |
| `vmStart.startTimeoutSeconds` | `120` | Wait for VM to reach running state |
| `vmStart.bootDelaySeconds` | `15` | Extra wait after running, before tests |
| `vmStart.testVmNamePrefix` | `"test-"` | Prefix for test VM names |
| `vmImage.refreshHours` | `24` | Hours between automatic re-downloads |
| `vmImage.alwaysRedownload` | `false` | Force re-download even if image exists |
| `vmCommunication.characterDelayMs` | `20` | ms between keystrokes in `inputText`/`inputTextAndEnter` (per-step `charDelayMs` in sequences/ overrides this default) |
| `vmCommunication.keystrokeMechanism` | `"GUI"` | `"GUI"` keystroke injection, `"SSH"` over ssh. Selects `sequences/gui/` or `sequences/ssh/`; SSH falls back to `gui/`. Any other value normalized to `"GUI"` |
| `vmCommunication.pollSeconds` | `5` | Default poll interval (seconds) for wait-style actions (`waitForText`, `passwdPrompt`, `waitForAndEnter`, `sshWaitReady`, …). A step's own `pollSeconds` overrides this default |
| `vmCommunication.timeoutSeconds` | `180` | Default timeout (seconds) for wait-style actions (`waitForText`, `passwdPrompt`, `fetchAndExecute`, `sshExec`, `sshWaitReady`, …). A step's own `timeoutSeconds` overrides this default |
| `vmCommunication.vncPort` | `5900` | Fallback VNC port when no VM name is given. Per-VM ports (5910..5989) are derived from the VM name by `Get-VncDisplayForVm` (`host/macos.utm/modules/Yuruna.Host.psm1`); each QEMU-backed UTM guest gets a unique port so concurrent VMs can't poach each other's framebuffer |
| `repositories.frameworkUrl` | `alissonsol/yuruna` | URL of the framework repo. Used by status page for commit links AND polled by the outer runner during a failure-pause to break out early when a new commit lands upstream. |
| `repositories.projectUrl` | `alissonsol/yuruna-project` | URL of the project-under-test repo. Polled alongside `repositories.frameworkUrl` during a failure-pause, so a fix pushed to the project also breaks out of the 1-hour wait. Empty value disables the project clone (in-tree `project/` is used instead). |
| `statusServer.isEnabled` | `true` | Start built-in HTTP status server |
| `statusServer.port` | `8080` | Port for status server |

### Format enforcement and auto-reset

At cycle start the runner overlays `test.config.yml.template` to pick up
any newly added keys. If the on-disk `test.config.yml` no longer matches
the nested node layout above — for example a checkout left over from the
old flat layout — the runner does **not** silently migrate it. Instead it:

1. Copies the current file to `test.config.yml.backup`.
2. Resets `test.config.yml` to the template defaults.
3. Warns and stops the test.

Copy any custom values from `test.config.yml.backup` into the new
`test.config.yml` by hand, then restart — the test will proceed normally.

### Guest ordering and skipping

Omit a guest from `guestSequence` to skip it. Listing one with no folder
marks a per-guest failure; others still run unless `testCycle.shouldStopOnFailure`.

### Notifications (Resend) — full setup

Notifications are dispatched by the active extension(s) under
[`test/extension/notification/`](extension/notification/). The shipped
default delivers email via Resend; subscribers are configured per
event code (`cycle.failure`, `config.smoke`).

1. Create a free account at [resend.com](https://resend.com).
2. Create an [API key](https://resend.com/api-keys) (starts with `re_`).
3. Add and verify a sender domain under
   [Domains](https://resend.com/domains), or use `onboarding@resend.dev`
   for testing.
4. Copy
   [`extension/notification/notification.transports.yml.template`](extension/notification/notification.transports.yml.template)
   to `extension/notification/notification.transports.yml` and fill in:
    - `transports.resend.apiKey`
    - `transports.resend.fromEmail`
    - `subscribers["cycle.failure"][].address` (one entry per recipient)
    - `subscribers["config.smoke"]` — leave empty unless you want
      `Test-Config.ps1` smoke runs to deliver mail.
5. Run `pwsh test/Test-Config.ps1` to validate the config and dispatch a
   `config.smoke` event end-to-end. The file is gitignored.

Legacy `secrets.resend` and `notification.toEmailAddress` keys in
`test.config.yml` are no longer read; the runner warns at cycle start
when it sees populated legacy values that need a manual move.

### Authentication vault (per-cycle credentials)

VM passwords come from the active extension under
[`test/extension/authentication/`](extension/authentication/). The
default extension keeps a YAML vault (`vault.yml`, gitignored) scoped
to a single test cycle:

- `Initialize-VaultConnection` runs once at cycle start.
- `Get-Password -Username <name>` returns the stored value or
  generates+stores one on first call.
- `New-RandomPassword` is a pure helper used by the rotation flow.
- `Set-Password -Username <name> -NewPassword <value>` commits a
  rotation.
- A named system mutex serialises read-modify-write so multiple guests
  provisioning in parallel cannot race.

The vault is wiped on cycle success (`Clear-VaultStorage`); a failed
cycle leaves it in plaintext for debugging. The squid-cache `yuruna`
user persists across cycles via
[`test/status/track/yuruna-caching-proxy.yml`](status/track/)
(host-agnostic, gitignored, managed by
[`test/modules/Test.CachingProxy.psm1`](modules/Test.CachingProxy.psm1)),
which the squid-cache `New-VM.ps1` writes back to the vault on each
cycle start. The same file also carries the cache VM's IP, replacing
the older per-platform `cache-ip.txt` breadcrumb near the VHD/raw
image.

The test user is configured per-guest in `test/sequences/**/*.yml`
(under `variables.username`) and mirrored as the `-Username` default
in each host's `guest.<type>/New-VM.ps1`. The names follow a
`y[aw]user1` pattern that encodes the guest family in the second
character: `yauser1` for amazon.linux, `yuuser1` for ubuntu.server,
`ywuser1` for windows.11 -- intentionally unique/greppable versus the
cloud-image defaults `ubuntu` and `ec2-user`. The trailing digit
anticipates the multi-user future (a second user per guest, etc.)
which will be defined in a manifest, not created on the fly.

Sequence steps fetch live values via the inline `${ext:area.Method(args)}`
substitution form, e.g. `${ext:authentication.GetPassword(${username})}` and
`${ext:authentication.NewRandomPassword()}`. Substitutions are memoised within a
single sequence run, so a `New password:` prompt and the matching
`Retype:` prompt receive the same generated value. Side-effecting
commits (e.g. `authentication.SetPassword`) use the `callExtension` action verb.

## Developing test sequences

[`Confirm-Sequence.ps1`](Confirm-Sequence.ps1) runs a single
sequence without downloading images or recreating a VM:

```powershell
pwsh test/Confirm-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server"
pwsh test/Confirm-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server" -StartStep 5
pwsh test/Confirm-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server" -StartStep 3 -StopStep 7
pwsh test/Confirm-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server" -VMName "private-ubuntu"
```

Pass the sequence **name** only (no folder, `.yml`, or `.ssh.` suffix);
the script resolves against `keystrokeMechanism`, falling back to
`gui/`. It prints a numbered step list with run markers; `-StopStep`
leaves the VM running. Missing sequence → listing from `sequences/gui/`
and `sequences/ssh/`.

Parameters: `-SequenceName` (required), `-StartStep` (default 1),
`-StopStep`, `-ConfigPath`, `-VMName`, `-logLevel`.

## Logging knobs

`-logLevel` accepts `Error|Warning|Information|Verbose|Debug`. Each level
shows itself plus all higher-priority streams (Error is highest); the
default is `Information`, so the runner's progress narration reaches the
console. Three-state resolution (cmdline > `test.config.yml` >
`Information`): omit the flag to read [test.config.yml](test.config.yml)'s
`logLevel`, or pass `-logLevel <level>` to override for the lifetime of
the runner. The level maps to PowerShell's preference variables:

| Level | Stream | Cmdlet | Use it for |
|-------|--------|--------|-----|
| Error       | 2 | `Write-Error`       | non-terminating errors only (silent narrative) |
| Warning     | 3 | `Write-Warning`     | + potential issues that don't stop execution |
| Information | 6 | `Write-Information` | + general progress (the runner's default narrative) |
| Verbose     | 4 | `Write-Verbose`     | + per-poll OCR hits, network re-applies (use when a `waitForText` hangs) |
| Debug       | 5 | `Write-Debug`       | + VNC capture ticks, screen-diff, AppleScript/CGEvent results |

## Status page details

`http://localhost:8080/status/` polls `status.json` every 30s and
shows pass/fail, per-guest step status (New-VM, Start-VM,
New-VM.Resource, Start-GuestOS, Screenshots, Start-GuestWorkload),
history, and clickable Cycle IDs. Stop
the detached server with `pwsh test/Stop-StatusServer.ps1`.

### SSH server on the host (optional)

Guests or peer hosts reach the test machine over SSH/SCP once sshd is
running. Not installed automatically. Install once
(`pwsh test/Start-SshServer.ps1`, elevated on Windows); uninstall with
`Stop-SshServer.ps1`. On Windows this adds the `OpenSSH.Server`
capability (minutes on first install), starts `sshd`, and enables
auto-start on boot. macOS is currently a placeholder.

Runtime enable/disable is config-driven: set `hostSshServer.enabled`
in [test.config.yml](test.config.yml) and the cycle runner applies it
each cycle via the
[`host-ssh-server` extension](extension/host-ssh-server/). The default
provider delegates to the active `Yuruna.Host` driver's SSH contract
(`Test-SshServerSupported`, `Test-SshServerInstalled`, `Start-SshServer`,
`Stop-SshServer`, `Get-SshServerStatus`); install remains a one-time
manual step (`pwsh test/Start-SshServer.ps1`). A future provider could
swap host-local sshd for a VM-based SSH endpoint without touching
callers — they only see the extension's `Enable-SshServer` /
`Disable-SshServer` / `Get-SshServerInfo` verbs.

## Screenshot-based testing

Train references once per guest:

```powershell
pwsh test/Train-Screenshots.ps1 -GuestKey guest.amazon.linux
```

The tool creates a VM and waits for capture commands:

| Command | Action |
|---------|--------|
| `c <name>` | Capture a checkpoint (e.g. `c boot-complete`) |
| `d` | Done — save schedule and exit |
| `q` | Quit without saving |

Training produces `test/screenshots/<guestKey>/schedule.json` and
`reference/*.png`. `schedule.json` is editable:

```json
{
  "checkpoints": [
    { "name": "boot-complete", "delaySeconds": 60, "threshold": 0.85 },
    { "name": "login-screen",  "delaySeconds": 120, "threshold": 0.80 }
  ]
}
```

`threshold` is minimum pixel-similarity to pass (0.85 = 85% match).
Per-run captures land in `screenshots/<guestKey>/captures/`
(git-ignored).

## Adding a test sequence

Drop a YAML sequence under `test/sequences/{gui,ssh}/` (framework
generic) or `project/<...>/test/{gui,ssh}/` (project-specific), wire
its `baseline` to declare prerequisites, then reference the top-level
sequence from `project/test/test.sequence.yml` `baseline`. Full
architecture: [modules/README.md](modules/README.md).

Back to [Test runner](README.md) · [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
