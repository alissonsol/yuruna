# Yuruna VDE Test Runner

Continuous VDE test cycle across hosts and guests. For the internal
architecture (modules, directories, sequences, extension API) see
[CODE.md](CODE.md).

## What it does

Cycle summary in [CODE.md](CODE.md). On first failure, the runner
leaves the VM running, sends a Resend notification, and exits.

## Prerequisites

Same as the VDE scripts — see
[virtual/host.macos.utm/README.md](../virtual/host.macos.utm/README.md) or
[virtual/host.windows.hyper-v/README.md](../virtual/host.windows.hyper-v/README.md).
Windows requires elevation; macOS does not.

## Configuration

Copy the template (it is git-ignored):

```powershell
cp test/test-config.json.template test/test-config.json
```

### Keys

| Key | Default | Description |
|-----|---------|-------------|
| `testVmNamePrefix` | `"test-"` | Prefix for test VM names |
| `cycleDelaySeconds` | `30` | Pause between cycles |
| `vmStartTimeoutSeconds` | `120` | Wait for VM to reach running state |
| `vmBootDelaySeconds` | `15` | Extra wait after running, before tests |
| `alwaysRedownloadImages` | `false` | Force re-download even if image exists |
| `getImageRefreshHours` | `24` | Hours between automatic re-downloads |
| `repoUrl` | `alissonsol/yuruna` | URL used by status page for commit links |
| `stopOnFailure` | `false` | `true` = stop on first failure and preserve VM; `false` = clean up and continue. Failure artifacts always copied to `status/log/` |
| `maxHistoryRuns` | `30` | Runs kept in status history |
| `charDelayMs` | `20` | ms between keystrokes in `type`/`typeAndEnter` |
| `keystrokeMechanism` | `"GUI"` | `"GUI"` keystroke injection, `"SSH"` over ssh. Selects `sequences/gui/` or `sequences/ssh/`; SSH falls back to `gui/`. Any other value normalized to `"GUI"` |
| `vncPort` | `5900` | Fallback VNC port when no VM name is given. Per-VM ports (5910..5989) are derived from the VM name by `Get-VncDisplayForVm` (`test/modules/Test.Screenshot.psm1`); each QEMU-backed UTM guest gets a unique port so concurrent VMs can't poach each other's framebuffer |
| `guestOrder` | _required_ | Array of guest keys; each must correspond to `virtual/<hostType>/<guestKey>/` |
| `statusServer.enabled` | `true` | Start built-in HTTP status server |
| `statusServer.port` | `8080` | Port for status server |

### Guest ordering and skipping

`guestOrder` controls which guests run and in what order. Any
`guest.<name>` is valid as long as `virtual/<hostType>/<guestKey>/`
exists on the current host — the runner discovers guests by folder, not
a hardcoded list. Adding a new guest = creating the folder with
`Get-Image.ps1` + `New-VM.ps1`; no harness code change.

Omit a guest to skip it. Listing one with no folder marks a per-guest
failure; others still run unless `stopOnFailure`.

### Notifications (Resend)

1. Create a free account at [resend.com](https://resend.com).
2. Create an [API key](https://resend.com/api-keys) (starts with `re_`).
3. Add and verify a sender domain under
   [Domains](https://resend.com/domains), or use `onboarding@resend.dev`
   for testing.
4. Set `secrets.resend.apiKey` and `secrets.resend.from` in
   `test-config.json`. Everything under the top-level `secrets` node is
   stripped from logged config.

### Validate

```powershell
pwsh test/Test-Config.ps1            # Live notification send
pwsh test/Test-Config.ps1 -SkipSend  # Skip the send
```

Each check prints `[PASS]`, `[WARN]`, or `[FAIL]`.

## Remote caching proxy

The runner auto-discovers a local `squid-cache` VM (see
[../docs/caching.md](../docs/caching.md)). Point at a remote proxy:

```powershell
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
pwsh test/Invoke-TestRunner.ps1
```

When set, `Invoke-TestRunner.ps1` and `Start-StatusServer.ps1` skip
local discovery. `New-VM.ps1` inherits the URL, fetches the CA from
`http://<remote>/yuruna-squid-ca.crt`, and wires apt to `<remote>:3128`
(HTTP) + `<remote>:3129` (HTTPS). Un-set to revert.

Preflight a cache:

```powershell
pwsh test/Test-CachingProxy.ps1   # YURUNA_CACHING_PROXY_IP or local
```

Probes `:3128`, `:3129`, `:80`, `:3000`, and the CA; exit 1 on any
required failure. Host-side setup for exposing a cache to remote
clients: [CachingProxy.md](CachingProxy.md).

## Usage

```powershell
pwsh test/Invoke-TestRunner.ps1                       # default
pwsh test/Invoke-TestRunner.ps1 -NoGitPull            # dev mode
pwsh test/Invoke-TestRunner.ps1 -NoServer             # headless
pwsh test/Invoke-TestRunner.ps1 -NoExtensionOutput    # suppress ext stdout
pwsh test/Invoke-TestRunner.ps1 -CycleDelaySeconds 60
pwsh test/Invoke-TestRunner.ps1 -debug_mode $true -verbose_mode $true
```

### Developing test sequences

[`Invoke-TestSequence.ps1`](Invoke-TestSequence.ps1) runs a single
sequence without downloading images or recreating a VM:

```powershell
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop"
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop" -StartStep 5
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop" -StartStep 3 -StopStep 7
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop" -VMName "private-ubuntu"
```

Pass the sequence **name** only (no folder, `.json`, or `.ssh.` suffix);
the script resolves against `keystrokeMechanism`, falling back to
`gui/`. It prints a numbered step list with run markers; `-StopStep`
leaves the VM running. Missing sequence → listing from `sequences/gui/`
and `sequences/ssh/`.

Parameters: `-SequenceName` (required), `-StartStep` (default 1),
`-StopStep`, `-ConfigPath`, `-VMName`, `-debug_mode`, `-verbose_mode`.

## Logging

Each cycle writes `test/status/log/{cycleId}.{hostname}.{gitCommit}.html`
(git-ignored; linked from the status page). The `yuruna-log` proxy
wraps `Write-Output/Error/Warning/Debug/Verbose/Information` so console
output lands in the log too.

- `-verbose_mode $true` — surfaces what each OCR engine reads
  (`[tesseract] no match | <last 120 chars>`) on every poll. Use it
  when a `waitForText` hangs and you want to see whether the screen is
  being captured and recognized.
- `-debug_mode $true` — adds low-level chatter: VNC capture ticks,
  screen-diff messages, polling timestamps, AppleScript/CGEvent
  results.

## Status page

While the runner is active: `http://localhost:8080/status/`. Polls
`status.json` every 30s; shows pass/fail, per-guest step status
(New-VM, Start-VM, Verify-VM, Screenshots, Invoke-PoolTest), history,
and clickable Cycle IDs. Stop the detached server with
`pwsh test/Stop-StatusServer.ps1`. Architecture: [CODE.md](CODE.md).

### SSH server on the host (optional)

Guests or peer hosts reach the test machine over SSH/SCP once sshd is
running. Not installed automatically. Install once (`pwsh
test/Start-SshServer.ps1`, elevated on Windows); uninstall with
`Stop-SshServer.ps1`. On Windows this adds the `OpenSSH.Server`
capability (minutes on first install), starts `sshd`, and enables
auto-start on boot. macOS is currently a placeholder.

The status banner's "Enable/Disable SSH Server" button reflects state:
disabled when OpenSSH isn't installed, Enable when installed but
stopped, Disable when running, N/A on unsupported hosts.

## Extensions

Drop `.ps1` files into `test/extensions/` — they run after each VM is
started. Quick example:

```powershell
# test/extensions/Test-Workload.guest.amazon.linux.check-ssh.ps1
param([string]$HostType, [string]$GuestKey, [string]$VMName)
& ssh -o ConnectTimeout=5 ec2-user@$VMName "echo ok"
exit $LASTEXITCODE
```

Full API: [extensions/README.md](extensions/README.md).

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

Exit codes are listed in [CODE.md](CODE.md#exit-codes).
