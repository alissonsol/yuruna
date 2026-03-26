# Yuruna VDE Test Runner

Automated test cycle for Virtual Development Environment guest creation.

## What it does

1. Detects the current host (`host.macos.utm` or `host.windows.hyper-v`)
2. Pulls the latest repo
3. For each supported guest (`guest.amazon.linux`, `guest.ubuntu.desktop`, `guest.windows.11`):
   - Downloads the base image (`Get-Image.ps1`) unless it already exists
   - Creates a test VM (`New-VM.ps1`) with a `test-` prefixed name
   - Verifies the VM bundle was created
   - Removes the test VM
4. Stops on the first error and sends a notification
5. Serves a live status page at `http://localhost:8080/status/`

## Prerequisites

The same prerequisites as the VDE scripts apply — see `vde/host.*/README.md` for each host.

### macOS (host.macos.utm)
- PowerShell Core (`brew install powershell`)
- UTM, QEMU tools, OpenSSL, Xcode CLI tools
- No elevation required

### Windows (host.windows.hyper-v)
- **Run as Administrator**
- Hyper-V enabled, PowerShell 7+
- Windows ADK Deployment Tools (Oscdimg.exe)
- For `guest.windows.11`: run `vde/host.windows.hyper-v/Get-Selenium.ps1` first

## Configuration

Edit `test/test-config.json` before first run:

```json
{
  "notification": {
    "type": "smtp",
    "toAddress": "ops@example.com",
    "smtp": {
      "server": "smtp.example.com",
      "port": 587,
      "useTls": true,
      "fromAddress": "vde-test@example.com",
      "username": "vde-test@example.com",
      "password": "your-password"
    }
  },
  "alwaysRedownloadImages": false,
  "cleanupAfterTest": true
}
```

For Slack/Teams webhooks, set `"type": "slack"` (or `"teams"`) and add:
```json
"webhook": { "url": "https://hooks.slack.com/services/..." }
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

# Use a custom config path
pwsh test/Invoke-TestRunner.ps1 -ConfigPath /path/to/my-config.json
```

## Status page

While the runner is active, open:

```
http://localhost:8080/status/
```

The page polls `status.json` every 30 seconds and shows:
- Overall pass/fail banner
- Per-guest status with step-level breakdown (GetImage, NewVM, VerifyVM, CleanupVM)
- History of recent runs

To serve the status page independently (after a run):

```bash
# macOS / Linux
cd test && python3 -m http.server 8080

# Windows PowerShell
cd test; python -m http.server 8080
```

Then open `http://localhost:8080/status/`.

## File structure

```
test/
  Invoke-TestRunner.ps1     # Entry point
  test-config.json          # User configuration
  modules/
    Test.Host.psm1          # Host detection, elevation, git
    Test.Status.psm1        # status.json management, HTTP server
    Test.Notify.psm1        # SMTP and webhook notifications
    Test.Runner.psm1        # Get-Image / New-VM invocation
    Test.Verify.psm1        # VM creation verification
    Test.Cleanup.psm1       # Test VM removal
  status/
    index.html              # Status page
    status.json             # Written by the runner (auto-created)
```

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All guests passed |
| `1`  | One or more guests failed, or pre-flight error |
