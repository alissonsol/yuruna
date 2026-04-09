# Yuruna VDE Test Runner

Automated continuous test cycle for Virtual Development Environment guest creation.

## What it does

The runner loops continuously (until a failure), executing this cycle:

1. Pulls the latest repo (`git pull`)
2. **Re-reads configuration** (`test-config.json` — picks up changes from git pull or local edits)
3. **Refresh images** (every 24 hours): downloads base images via `Get-Image.ps1`
4. **For each guest** (configurable via `guestOrder` — defaults to all three):
   - **Cleanup** — removes the previous test VM for this guest (if any)
   - **New-VM** — creates a test VM via `New-VM.ps1`
   - **Start-VM** — starts the VM (UTM `utmctl` / Hyper-V `Start-VM`)
   - **Verify-VM** — polls until the VM reaches running state
   - **Invoke-PoolTest** — runs extension scripts from `test/extensions/` (if any)
5. Logs the result and starts the next cycle
6. On first failure: leaves the VM running for investigation, sends a notification, and exits

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
  "getImageRefreshHours": 24,
  "testVmNamePrefix": "test-",
  "cycleDelaySeconds": 30,
  "vmStartTimeoutSeconds": 120,
  "statusServer": {
    "port": 8080,
    "enabled": true
  },
  "maxHistoryRuns": 30,
  "guestOrder": ["guest.amazon.linux", "guest.ubuntu.desktop", "guest.windows.11"]
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
| `getImageRefreshHours` | `24` | Hours between automatic image re-downloads |
| `maxHistoryRuns` | `30` | Number of runs kept in status history |
| `charDelayMs` | `20` | Default delay in ms between keystrokes in `type`/`typeAndEnter` actions |
| `verifyScreenshotThreshold` | `0.85` | Similarity threshold (0–1) for verify-screenshot comparison |
| `guestOrder` | all three | Array of guest keys to test, in execution order (see below) |
| `statusServer.enabled` | `true` | Start the built-in HTTP status server |
| `statusServer.port` | `8080` | Port for the status server |

### Guest ordering and skipping

The `guestOrder` array in `test-config.json` controls which guests are tested and
in what order. When omitted, all three guests run in the default order:
`guest.amazon.linux`, `guest.ubuntu.desktop`, `guest.windows.11`.

To change the order (e.g. test Ubuntu Desktop before Amazon Linux):

```json
"guestOrder": ["guest.ubuntu.desktop", "guest.amazon.linux", "guest.windows.11"]
```

To skip a guest, omit it from the array:

```json
"guestOrder": ["guest.ubuntu.desktop", "guest.amazon.linux"]
```

To run only a single guest:

```json
"guestOrder": ["guest.windows.11"]
```

Unknown guest keys in the array are warned about and ignored. To restore the
default behavior, remove the `guestOrder` key entirely.

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

# Suppress extension script output
pwsh test/Invoke-TestRunner.ps1 -NoExtensionOutput

# Custom cycle delay
pwsh test/Invoke-TestRunner.ps1 -CycleDelaySeconds 60

# Enable debug output (internal step details, OCR engine results)
pwsh test/Invoke-TestRunner.ps1 -debug_mode $true

# Enable verbose output (additional diagnostic messages)
pwsh test/Invoke-TestRunner.ps1 -verbose_mode $true
```

## Developing test sequences

The `Invoke-TestSequence.ps1` script helps iterate on sequence JSON files during
development. Unlike `Invoke-TestRunner.ps1`, it:

- Does **not** download images
- **Reuses** an existing VM if one is already created (only creates if needed)
- Runs a **single** named sequence (no continuous loop)
- Can **start at any step** within the sequence

### Usage

```powershell
# Run a workload sequence from the beginning
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop"

# Resume from step 5 (useful when iterating on later steps)
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop" -StartStep 5

# Run only steps 3 through 7 (VM is left running for inspection)
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Workload.guest.ubuntu.desktop" -StartStep 3 -StopStep 7

# Run an OS install sequence from step 3
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.amazon.linux" -StartStep 3

# Enable debug output (internal step details, OCR engine results)
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.amazon.linux" -debug_mode $true

# Enable verbose output (additional diagnostic messages)
pwsh test/Invoke-TestSequence.ps1 -SequenceName "Test-Start.guest.amazon.linux" -verbose_mode $true
```

The script prints a numbered step list before execution, marking which steps will
run. If the sequence file is not found, it lists all available sequences.

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-SequenceName` | Yes | — | Base name of the sequence (e.g. `Test-Workload.guest.ubuntu.desktop`) |
| `-StartStep` | No | `1` | 1-based step number to start from |
| `-StopStep` | No | — | 1-based step number to stop at (inclusive); VM is left running |
| `-ConfigPath` | No | `test/test-config.json` | Path to config file |
| `-debug_mode` | No | `$false` | Show debug messages (internal step details, OCR engine results) |
| `-verbose_mode` | No | `$false` | Show verbose messages (additional diagnostics) |

## Logging

Every test cycle writes a log to `test/status/log/`. The `yuruna-log` proxy
module (`automation/yuruna-log.psm1`) overrides the built-in `Write-Output`,
`Write-Error`, `Write-Warning`, `Write-Debug`, `Write-Verbose`, and
`Write-Information` cmdlets so that all output is appended to the log file
in addition to appearing on the console. The `debug_mode` and `verbose_mode`
flags control how much detail appears on screen and in the log.

Log files are named `{runId}.{hostname}.{gitCommit}.txt` and are git-ignored.
The status page links each Run ID to its log file for easy inspection.

## Status page

While the runner is active, open:

```
http://localhost:8080/status/
```

The page polls `status.json` every 30 seconds and shows:
- Overall pass/fail banner
- Per-guest status with step-level breakdown (New-VM, Start-VM, Verify-VM, Screenshots, Invoke-PoolTest)
- History of recent runs
- Clickable Run ID links to the corresponding log file

### How the status page is served

The runner launches `Start-StatusServer.ps1`, which starts a detached `pwsh`
process hosting a lightweight HTTP server (`System.Net.HttpListener` bound to
`http://*:<port>/`). The server runs independently of the runner — stopping
`Invoke-TestRunner.ps1` does not stop the status server. The runner checks at
the start of each cycle whether the server is still alive and restarts it if
needed.

The server serves files from the `test/status/` directory (including
`log/*.txt` transcript files). The runner writes `status.json` atomically
(write to `.tmp`, then rename) so the page always reads a complete document.

To stop the server manually:

```powershell
pwsh test/Stop-StatusServer.ps1
```

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

The runner discovers extension scripts automatically. The `Invoke-PoolTest` step
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
2. After Verify-VM confirms the VM is running, the boot delay elapses
3. For each checkpoint: wait `delaySeconds`, capture a screenshot, compare
4. If similarity drops below threshold, the `Screenshots` step fails
5. The VM is stopped before the next guest starts

Captures from each run are saved to `test/screenshots/<guestKey>/captures/`
(git-ignored) for post-mortem inspection.

## Module architecture

```
test/
  Invoke-TestRunner.ps1           # Entry point — continuous loop orchestrator
  Invoke-TestSequence.ps1          # Dev helper — run a single sequence from any step
  Start-StatusServer.ps1          # Launches detached HTTP status server
  Stop-StatusServer.ps1           # Stops the detached status server
  Test-Config.ps1                 # Validates config and sends a test notification
  Train-Screenshots.ps1           # Interactive screenshot training tool
  Remove-TestVMFiles.ps1          # Stops and removes all test VMs and files
  test-config.json.template       # Configuration template (committed)
  test-config.json                # Your local configuration (git-ignored)
  modules/
    Get-NewText.psm1              # Diff-based OCR text extraction (pure C#)
    Test.Host.psm1                # Host detection, elevation, git operations
    Test.Status.psm1              # status.json document management
    Test.StatusServer.psm1        # HTTP status server start/stop
    Test.Notify.psm1              # Resend API email notifications
    Test.Get-Image.psm1           # Base image download and refresh
    Test.Log.psm1                 # Transcript logging to test/status/log/
    Test.LogDir.psm1              # YurunaLog directory path management
    Test.New-VM.psm1              # VM creation, verification, and cleanup
    Test.Install-OS.psm1          # OS installation sequence orchestration
    Test.Start-VM.psm1            # VM start, stop, boot verification
    Test.Invoke-PoolTest.psm1     # Extension test discovery and execution
    Test.Screenshot.psm1          # Screenshot capture, comparison, schedule
    Test.OcrEngine.psm1           # Pluggable OCR engine registry
    Test.Tesseract.psm1           # Tesseract OCR utilities
  extensions/
    README.md                                       # Extension API documentation
    Invoke-Sequence.psm1                            # JSON sequence interpreter
    Test-Start.guest.amazon.linux.ps1               # Amazon Linux OS install
    Test-Start.guest.ubuntu.desktop.ps1             # Ubuntu Desktop OS install
    Test-Start.guest.windows.11.ps1                 # Windows 11 OS install
    Test-Workload.guest.amazon.linux.ps1            # Amazon Linux workload test
    Test-Workload.guest.ubuntu.desktop.ps1          # Ubuntu Desktop workload test
    Test-Workload.guest.windows.11.ps1              # Windows 11 workload test
  verify/
    expected/                     # Reference PNGs (committed)
    actual/                       # Runtime captures (git-ignored)
  status/
    index.html                    # Status dashboard
    status.json.template          # Template for status data
    status.json                   # Written by the runner (auto-created, git-ignored)
    server.pid                    # Status server PID (auto-created, git-ignored)
    log/                          # Transcript logs per run (git-ignored .txt files)
```

### Module responsibilities

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `Get-NewText` | Diff-based OCR text extraction (pure C#) | `Get-NewTextContent`, `Get-ProcessedScreenImage` |
| `Test.Host` | Platform detection, elevation checks, git | `Get-HostType`, `Get-GuestList`, `Assert-Elevation`, `Invoke-GitPull` |
| `Test.Status` | Status document lifecycle | `Initialize-StatusDocument`, `Set-StepStatus`, `Complete-Run` |
| `Test.StatusServer` | HTTP status server management | `Start-StatusServer`, `Stop-StatusServer` |
| `Test.Notify` | Email notifications via Resend API | `Send-Notification`, `Format-FailureMessage` |
| `Test.Get-Image` | Base image download/refresh | `Get-ImagePath`, `Invoke-GetImage` |
| `Test.Log` | Transcript logging to `test/status/log/` | `Start-LogFile`, `Stop-LogFile` |
| `Test.LogDir` | YurunaLog directory path management | `Get-YurunaLogDir` |
| `Test.New-VM` | VM create + verify creation + cleanup | `Invoke-NewVM`, `Confirm-VMCreated`, `Remove-TestVM` |
| `Test.Install-OS` | OS installation sequence orchestration | `Get-StartTestScript`, `Invoke-StartTest`, `Get-VerifyScreenshot` |
| `Test.Start-VM` | VM start/stop + verify running | `Invoke-StartVM`, `Stop-TestVM`, `Confirm-VMStarted` |
| `Test.Invoke-PoolTest` | Extension test discovery and execution | `Get-GuestTestScript`, `Invoke-PoolTest` |
| `Test.Screenshot` | Screenshot capture, comparison, schedules | `Get-VMScreenshot`, `Compare-Screenshot`, `Invoke-ScreenshotTest` |
| `Test.OcrEngine` | Pluggable OCR engine registry | `Register-OcrProvider`, `Get-EnabledOcrProvider`, `Invoke-WinRtOcr` |
| `Test.Tesseract` | Tesseract OCR utilities | `Find-Tesseract`, `Assert-TesseractInstalled`, `Invoke-TesseractOcr` |

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All guests passed (runner was interrupted or completed) |
| `1`  | One or more guests failed, or pre-flight error |
