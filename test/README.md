# Yuruna VDE Test Runner

Automated continuous test cycle for Virtual Development Environment guest creation.

## What it does

The runner loops continuously (until a failure), executing this cycle:

1. Pulls the latest repo (`git pull`)
2. **Refresh images** (every 24 hours): downloads base images via `Get-Image.ps1`
3. **Cleanup**: removes all previous test VMs in a block
4. **For each guest** (`guest.amazon.linux`, `guest.ubuntu.desktop`, `guest.windows.11`):
   - **NewVM** — creates a test VM via `New-VM.ps1`
   - **StartVM** — starts the VM (UTM `utmctl` / Hyper-V `Start-VM`)
   - **VerifyVM** — polls until the VM reaches running state
   - **CustomTests** — runs extension scripts from `test/extensions/` (if any)
5. Logs the result and starts the next cycle
6. On first failure: sends a notification and exits

## Prerequisites

The same prerequisites as the VDE scripts apply — see `vde/host.*/README.md` for each host.

### macOS (host.macos.utm)
- PowerShell Core (`brew install powershell`)
- UTM, QEMU tools, OpenSSL, Xcode CLI tools
- `utmctl` in PATH (ships with UTM)
- No elevation required

### Windows (host.windows.hyper-v)
- **Run as Administrator**
- Hyper-V enabled, PowerShell 7+
- Windows ADK Deployment Tools (Oscdimg.exe)
- For `guest.windows.11`: run `vde/host.windows.hyper-v/Get-Selenium.ps1` first

## Configuration

Copy the template and edit your local copy before first run:

```powershell
cp test/test-config.json.template test/test-config.json
```

Then edit `test/test-config.json` (it is git-ignored and will not be committed):

```json
{
  "notification": {
    "toAddress": "recipient@example.com",
    "resend": {
      "apiKey": "re_your_api_key",
      "from": "Yuruna VDE <notifications@yourdomain.com>"
    }
  },
  "alwaysRedownloadImages": false,
  "testVmNamePrefix": "test-",
  "cycleDelaySeconds": 30,
  "vmStartTimeoutSeconds": 120,
  "statusServer": {
    "port": 8080,
    "enabled": true
  },
  "maxHistoryRuns": 30
}
```

### Configuration keys

| Key | Default | Description |
|-----|---------|-------------|
| `testVmNamePrefix` | `"test-"` | Prefix for test VM names |
| `cycleDelaySeconds` | `30` | Pause between cycles |
| `vmStartTimeoutSeconds` | `120` | How long to wait for a VM to reach running state |
| `vmBootDelaySeconds` | `15` | Extra wait after VM is running, before screenshots/tests |
| `alwaysRedownloadImages` | `false` | Force re-download even if image exists |
| `maxHistoryRuns` | `30` | Number of runs kept in status history |
| `statusServer.enabled` | `true` | Start the built-in HTTP status server |
| `statusServer.port` | `8080` | Port for the status server |

### Setting up notifications

Notifications are sent via the [Resend](https://resend.com) email API.

**One-time Resend setup:**

1. Create a free account at [resend.com](https://resend.com).
2. Go to [API Keys](https://resend.com/api-keys) and create a new API key. Copy the key (it starts with `re_`).
3. Add and verify your sending domain under [Domains](https://resend.com/domains), or use the provided `onboarding@resend.dev` address for testing.
4. Set `notification.resend.apiKey` to your API key and `notification.resend.from` to your verified sender address in `test-config.json`.

**Domain verification:** To send from your own domain (rather than `onboarding@resend.dev`), you must register the domain with Resend and add the DNS records (typically TXT and/or MX) that Resend provides to verify domain ownership.

## Verifying your configuration

After editing `test/test-config.json`, run the config checker:

```powershell
pwsh test/Test-Config.ps1
```

Each check prints `[PASS]`, `[WARN]`, or `[FAIL]` with diagnostic detail.

```powershell
# Validate settings only — skip the live notification send
pwsh test/Test-Config.ps1 -SkipSend
```

## Usage

```powershell
# macOS — from any terminal with PowerShell
cd /path/to/yuruna
pwsh test/Invoke-TestRunner.ps1

# Windows — from an elevated PowerShell prompt
cd C:\path\to\yuruna
pwsh test\Invoke-TestRunner.ps1

# Skip git pull (useful during development)
pwsh test/Invoke-TestRunner.ps1 -NoGitPull

# Skip the HTTP server (run headless)
pwsh test/Invoke-TestRunner.ps1 -NoServer

# Custom cycle delay
pwsh test/Invoke-TestRunner.ps1 -CycleDelaySeconds 60
```

## Status page

While the runner is active, open:

```
http://localhost:8080/status/
```

The page polls `status.json` every 30 seconds and shows:
- Overall pass/fail banner
- Per-guest status with step-level breakdown (NewVM, StartVM, VerifyVM, Screenshots, CustomTests)
- History of recent runs

### How the status page is served

The runner starts a lightweight HTTP server as a PowerShell background job
(`Test.StatusServer.psm1`). It uses `System.Net.HttpListener` bound to
`http://localhost:<port>/` and serves files from the `test/status/` directory.
The runner writes `status.json` atomically (write to `.tmp`, then rename) so
the page always reads a complete document.

To serve the status page independently (after a run has written `status.json`):

```bash
# macOS / Linux
cd test && python3 -m http.server 8080

# Windows PowerShell
cd test; python -m http.server 8080
```

Then open `http://localhost:8080/status/`.

## Extending with custom tests

Place `.ps1` scripts in `test/extensions/` to run custom validation after each
VM is started. See [extensions/README.md](extensions/README.md) for the full API.

Quick example — verify SSH connectivity:

```powershell
# test/extensions/Test-Workload.guest.amazon.linux.check-ssh.ps1
param([string]$HostType, [string]$GuestKey, [string]$VMName)
& ssh -o ConnectTimeout=5 ec2-user@$VMName "echo ok"
exit $LASTEXITCODE
```

The runner discovers extension scripts automatically. The `CustomTests` step
appears in the status page when any extension exists.

## Screenshot-based testing

The runner can compare the VM screen at specific moments against pre-trained
reference screenshots. This catches visual regressions (boot failures, UI
changes, installer prompts) that state-polling alone would miss.

### Training reference screenshots

Run the interactive training tool for each guest:

```powershell
pwsh test/Train-Screenshots.ps1 -GuestKey guest.amazon.linux
pwsh test/Train-Screenshots.ps1 -GuestKey guest.ubuntu.desktop
pwsh test/Train-Screenshots.ps1 -GuestKey guest.windows.11
```

The tool creates a VM, starts it, and waits for you to capture screenshots at
key moments. Commands during training:

| Command | Action |
|---------|--------|
| `c boot-complete` | Capture a screenshot named "boot-complete" |
| `c login-screen` | Capture another checkpoint |
| `d` | Done — save the schedule and exit |
| `q` | Quit without saving |

Training produces:
- `test/screenshots/<guestKey>/schedule.json` — checkpoint timing and thresholds
- `test/screenshots/<guestKey>/reference/*.png` — reference images

### Schedule format

The `schedule.json` file is editable. Each checkpoint specifies when to capture
and how strict the comparison should be:

```json
{
  "guestKey": "guest.amazon.linux",
  "hostType": "host.macos.utm",
  "trainedAt": "2026-03-26T10:00:00Z",
  "vmName": "test-amazon-linux01",
  "checkpoints": [
    { "name": "boot-complete", "delaySeconds": 60, "threshold": 0.85 },
    { "name": "login-screen",  "delaySeconds": 120, "threshold": 0.80 }
  ]
}
```

- `delaySeconds` — seconds after VM start to capture
- `threshold` — minimum similarity (0.0–1.0) to pass; 0.85 means 85% pixel match

### How it works during test runs

1. The runner starts one guest VM at a time (to avoid window overlap)
2. After VerifyVM confirms the VM is running, the boot delay elapses
3. For each checkpoint: wait `delaySeconds`, capture a screenshot, compare
4. If similarity drops below threshold, the `Screenshots` step fails
5. The VM is stopped before the next guest starts

Captures from each run are saved to `test/screenshots/<guestKey>/captures/`
(git-ignored) for post-mortem inspection.

## Module architecture

```
test/
  Invoke-TestRunner.ps1           # Entry point — continuous loop orchestrator
  Test-Config.ps1                 # Validates config and sends a test notification
  test-config.json.template       # Configuration template (committed)
  test-config.json                # Your local configuration (git-ignored)
  modules/
    Test.Host.psm1                # Host detection, elevation, git operations
    Test.Status.psm1              # status.json document management
    Test.StatusServer.psm1        # HTTP server for the status page
    Test.Notify.psm1              # Resend API email notifications
    Test.Get-Image.psm1           # Base image download and refresh
    Test.New-VM.psm1              # VM creation, verification, and cleanup
    Test.Start-VM.psm1            # VM start, stop, boot verification, custom tests
    Test.Screenshot.psm1          # Screenshot capture, comparison, schedule
  extensions/
    README.md                                       # Extension API documentation
    Test-Workload.guest.amazon.linux.ps1             # Amazon Linux workload test
    Test-Workload.guest.ubuntu.desktop.ps1           # Ubuntu Desktop workload test
    Test-Workload.guest.windows.11.ps1               # Windows 11 workload test
  screenshots/
    guest.amazon.linux/
      schedule.json               # Checkpoint timing and thresholds
      reference/                  # Trained reference PNGs (committed)
      captures/                   # Runtime captures (git-ignored)
  status/
    index.html                    # Status dashboard
    status.json.template          # Template for status data
    status.json                   # Written by the runner (auto-created, git-ignored)
```

### Module responsibilities

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `Test.Host` | Platform detection, elevation checks, git | `Get-HostType`, `Get-GuestList`, `Assert-Elevation`, `Invoke-GitPull` |
| `Test.Status` | Status document lifecycle | `Initialize-StatusDocument`, `Set-StepStatus`, `Complete-Run` |
| `Test.StatusServer` | HTTP server for status page | `Start-StatusServer`, `Stop-StatusServer` |
| `Test.Notify` | Email notifications via Resend API | `Send-Notification`, `Format-FailureMessage` |
| `Test.Get-Image` | Base image download/refresh | `Get-ImagePath`, `Invoke-GetImage` |
| `Test.New-VM` | VM create + verify creation + cleanup | `Invoke-NewVM`, `Confirm-VMCreated`, `Remove-TestVM` |
| `Test.Start-VM` | VM start/stop + verify running + extensions | `Invoke-StartVM`, `Stop-TestVM`, `Confirm-VMStarted`, `Invoke-GuestTests` |
| `Test.Screenshot` | Screenshot capture, comparison, schedules | `Get-VMScreenshot`, `Compare-Screenshots`, `Invoke-ScreenshotTests` |

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All guests passed (runner was interrupted or completed) |
| `1`  | One or more guests failed, or pre-flight error |
