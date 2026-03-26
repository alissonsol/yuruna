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
  "cleanupAfterTest": true,
  "testVmNamePrefix": "test-",
  "statusServer": {
    "port": 8080,
    "enabled": true
  },
  "maxHistoryRuns": 30
}
```

### Setting up notifications

Notifications are sent via the [Resend](https://resend.com) email API. Any SMTP-capable email provider (SendGrid, Mailgun, Amazon SES, etc.) could be used instead, but that would require changing the notification code in `modules/Test.Notify.psm1`.

**One-time Resend setup:**

1. Create a free account at [resend.com](https://resend.com).
2. Go to [API Keys](https://resend.com/api-keys) and create a new API key. Copy the key (it starts with `re_`).
3. Add and verify your sending domain under [Domains](https://resend.com/domains), or use the provided `onboarding@resend.dev` address for testing.
4. Set `notification.resend.apiKey` to your API key and `notification.resend.from` to your verified sender address in `test-config.json`.

**Domain verification:** To send from your own domain (rather than `onboarding@resend.dev`), you must register the domain with Resend and add the DNS records (typically TXT and/or MX) that Resend provides to verify domain ownership. Your DNS provider's dashboard is where you add these records. Resend will not deliver mail from an unverified domain.

## Verifying your configuration

After editing `test/test-config.json`, run the config checker to validate settings and send a test notification before launching the full test cycle:

```powershell
pwsh test/Test-Config.ps1
```

Each check prints `[PASS]`, `[WARN]`, or `[FAIL]` with diagnostic detail. A test notification is sent at the end so you can confirm delivery end-to-end.

```powershell
# Validate settings only — skip the live notification send
pwsh test/Test-Config.ps1 -SkipSend

# Use a custom config path
pwsh test/Test-Config.ps1 -ConfigPath /path/to/my-config.json
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
  test-config.json.template # Configuration template (committed)
  test-config.json          # Your local configuration (git-ignored)
  Test-Config.ps1           # Validates config and sends a test notification
  modules/
    Test.Host.psm1          # Host detection, elevation, git
    Test.Status.psm1        # status.json management, HTTP server
    Test.Notify.psm1        # Resend API email notifications
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
