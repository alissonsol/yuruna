<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456708
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    Validates test-config.json and sends a test notification to confirm it works.

.DESCRIPTION
    Checks that test-config.json exists and is well-formed, validates all required
    fields for the configured notification type (smtp, slack, teams, webhook), probes
    network connectivity where possible, and finally sends a live test notification.
    Each check prints a PASS / FAIL / WARN line with diagnostic detail so you can
    fix problems before running the full test cycle.

.PARAMETER ConfigPath
    Path to the config file. Defaults to test/test-config.json next to this script.

.PARAMETER SkipSend
    Validate the config but do not actually send a notification.

.EXAMPLE
    pwsh test/Test-Config.ps1

.EXAMPLE
    pwsh test/Test-Config.ps1 -SkipSend
#>

param(
    [string]$ConfigPath = $null,
    [switch]$SkipSend
)

$TestRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }
$TemplatePath = Join-Path $TestRoot "test-config.json.template"

# ── helpers ──────────────────────────────────────────────────────────────────

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

function Write-Pass  { param([string]$msg) Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:PassCount++ }
function Write-Fail  { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:FailCount++ }
function Write-Warn  { param([string]$msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:WarnCount++ }
function Write-Info  { param([string]$msg) Write-Host "        $msg"  -ForegroundColor Cyan }
function Write-Section { param([string]$msg) Write-Host "`n=== $msg ===" -ForegroundColor White }

# Returns $true when a value is a non-empty string, $false otherwise.
function Is-Set { param($v) return ($null -ne $v -and "$v".Trim() -ne "") }

# ── Section 1: Config file ────────────────────────────────────────────────────

Write-Section "Config file"

if (-not (Test-Path $ConfigPath)) {
    Write-Fail "Config file not found: $ConfigPath"
    if (Test-Path $TemplatePath) {
        Write-Info "To create it, run:"
        Write-Info "  cp test/test-config.json.template test/test-config.json"
        Write-Info "Then edit test/test-config.json with your notification settings."
    } else {
        Write-Info "Template not found either ($TemplatePath). Check your repository."
    }
    exit 1
}
Write-Pass "Config file found: $ConfigPath"

# ── Section 2: JSON parsing ───────────────────────────────────────────────────

Write-Section "JSON structure"

try {
    $Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable
    Write-Pass "JSON is valid and parsed successfully."
} catch {
    Write-Fail "JSON parse error: $_"
    Write-Info "Open test-config.json and fix the syntax error above."
    exit 1
}

# ── Section 3: Top-level fields ───────────────────────────────────────────────

Write-Section "Top-level settings"

if ($Config.ContainsKey("notification")) {
    Write-Pass "'notification' block is present."
} else {
    Write-Fail "'notification' block is missing."
}

if ($Config.ContainsKey("alwaysRedownloadImages")) {
    Write-Pass "'alwaysRedownloadImages' = $($Config.alwaysRedownloadImages)"
} else {
    Write-Warn "'alwaysRedownloadImages' not set — defaults to false."
}

if ($Config.ContainsKey("cleanupAfterTest")) {
    Write-Pass "'cleanupAfterTest' = $($Config.cleanupAfterTest)"
} else {
    Write-Warn "'cleanupAfterTest' not set — defaults to false (VMs will not be removed)."
}

if ($Config.ContainsKey("testVmNamePrefix")) {
    Write-Pass "'testVmNamePrefix' = '$($Config.testVmNamePrefix)'"
} else {
    Write-Warn "'testVmNamePrefix' not set — defaults to 'test-'."
}

if ($Config.ContainsKey("maxHistoryRuns")) {
    $mhr = [int]$Config.maxHistoryRuns
    if ($mhr -gt 0) { Write-Pass "'maxHistoryRuns' = $mhr" }
    else            { Write-Warn "'maxHistoryRuns' is $mhr — should be a positive integer." }
} else {
    Write-Warn "'maxHistoryRuns' not set — defaults to 30."
}

if ($Config.ContainsKey("statusServer")) {
    $ss = $Config.statusServer
    Write-Pass "'statusServer' block present (enabled=$($ss.enabled), port=$($ss.port))."
} else {
    Write-Warn "'statusServer' not set — status HTTP server will be disabled."
}

# Abort here if notification block is missing; nothing more to check.
if (-not $Config.ContainsKey("notification")) { exit 1 }

$notif = $Config.notification

# ── Section 4: Notification type ─────────────────────────────────────────────

Write-Section "Notification type"

$notifType = "$($notif.type)".ToLower().Trim()
$validTypes = @("smtp", "slack", "teams", "webhook")

if (-not (Is-Set $notifType)) {
    Write-Fail "'notification.type' is not set. Valid values: $($validTypes -join ', ')."
    exit 1
}

if ($notifType -notin $validTypes) {
    Write-Fail "'notification.type' is '$notifType'. Valid values: $($validTypes -join ', ')."
    exit 1
}

Write-Pass "'notification.type' = '$notifType'."

# ── Section 5a: SMTP checks ───────────────────────────────────────────────────

if ($notifType -eq "smtp") {

    Write-Section "SMTP settings"

    $smtp = $notif.smtp

    if (-not $smtp) {
        Write-Fail "'notification.smtp' block is missing."
        exit 1
    }

    foreach ($field in @("server", "fromAddress")) {
        if (Is-Set $smtp[$field]) { Write-Pass "smtp.$field = '$($smtp[$field])'" }
        else                      { Write-Fail "smtp.$field is not set." }
    }

    if (Is-Set $notif.toAddress) { Write-Pass "notification.toAddress = '$($notif.toAddress)'" }
    else                         { Write-Fail "notification.toAddress is not set." }

    $port = if ($smtp.ContainsKey("port")) { [int]$smtp.port } else { 587 }
    if ($port -gt 0 -and $port -lt 65536) { Write-Pass "smtp.port = $port" }
    else                                  { Write-Fail "smtp.port '$port' is not a valid port number." }

    $useTls = if ($smtp.ContainsKey("useTls")) { [bool]$smtp.useTls } else { $true }
    Write-Pass "smtp.useTls = $useTls"

    if (Is-Set $smtp.username) {
        Write-Pass "smtp.username = '$($smtp.username)'"
        if (Is-Set $smtp.password) { Write-Pass "smtp.password is set (not shown)." }
        else                       { Write-Warn "smtp.username is set but smtp.password is empty — authentication may fail." }
    } else {
        Write-Warn "smtp.username is empty — will attempt unauthenticated relay."
    }

    # Outlook / Hotmail detection
    $fromAddr  = "$($smtp.fromAddress)".ToLower()
    $isOutlook = ($fromAddr -like '*@outlook.com' -or $fromAddr -like '*@hotmail.com')
    if ($isOutlook) {
        Write-Pass "Outlook/Hotmail account detected — app password credential path will be used."
        $expectedServer = "smtp-mail.outlook.com"
        if ("$($smtp.server)".Trim() -ne $expectedServer) {
            Write-Warn "smtp.server is '$($smtp.server)' but Outlook requires '$expectedServer'."
            Write-Info "Update smtp.server to '$expectedServer' in test-config.json."
        } else {
            Write-Pass "smtp.server is correctly set to '$expectedServer'."
        }
        if (-not (Is-Set $smtp.password)) {
            Write-Fail "smtp.password must be set to an App Password for Outlook/Hotmail accounts."
            Write-Info "Generate one at: https://account.microsoft.com/security"
            Write-Info "Enable Two-Step Verification, then create an App Password under Advanced security options."
        } else {
            Write-Info "Ensure smtp.password is a Microsoft App Password, not your regular account password."
            Write-Info "Regular passwords are rejected by Microsoft for SMTP. See the README for setup steps."
        }
    }

    # Abort if any FAIL was recorded before network checks.
    if ($script:FailCount -gt 0) {
        Write-Host "`nFix the errors above before testing network connectivity." -ForegroundColor Red
        exit 1
    }

    # DNS resolution
    Write-Section "SMTP connectivity"
    $server = $smtp.server
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($server)
        Write-Pass "DNS resolved '$server' -> $($resolved[0].IPAddressToString)"
    } catch {
        Write-Fail "DNS resolution failed for '$server': $_"
        Write-Info "Check that smtp.server is spelled correctly and DNS is available."
        exit 1
    }

    # TCP connect (5-second timeout)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($server, $port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(5000, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            Write-Pass "TCP connection to ${server}:${port} succeeded."
        } else {
            Write-Fail "TCP connection to ${server}:${port} timed out."
            Write-Info "Verify the server address, port, and that no firewall is blocking outbound SMTP."
        }
        $tcp.Close()
    } catch {
        Write-Fail "TCP connection to ${server}:${port} failed: $_"
    }
}

# ── Section 5b: Webhook / Slack / Teams checks ────────────────────────────────

if ($notifType -in @("slack", "teams", "webhook")) {

    Write-Section "Webhook settings"

    $wh = $notif.webhook
    if (-not $wh) {
        Write-Fail "'notification.webhook' block is missing."
        exit 1
    }

    if (Is-Set $wh.url) {
        $url = $wh.url
        Write-Pass "notification.webhook.url is set."
        try {
            $uri = [System.Uri]::new($url)
            if ($uri.Scheme -in @("http","https")) {
                Write-Pass "URL scheme is '$($uri.Scheme)', host is '$($uri.Host)'."
            } else {
                Write-Fail "URL scheme '$($uri.Scheme)' is not http or https."
            }
        } catch {
            Write-Fail "webhook.url is not a valid URI: $_"
        }
    } else {
        Write-Fail "notification.webhook.url is not set."
    }

    if ($notifType -eq "teams") {
        Write-Info "Teams webhooks use the MessageCard schema — make sure your URL is an 'Incoming Webhook' connector URL."
    }

    if ($script:FailCount -gt 0) {
        Write-Host "`nFix the errors above before sending a test notification." -ForegroundColor Red
        exit 1
    }
}

# ── Section 6: Live send ──────────────────────────────────────────────────────

Write-Section "Live test notification"

if ($SkipSend) {
    Write-Warn "Skipping live send (-SkipSend was specified)."
} elseif ($script:FailCount -gt 0) {
    Write-Warn "Skipping live send because earlier checks failed."
} else {
    $ModulesDir = Join-Path $TestRoot "modules"
    $notifyMod  = Join-Path $ModulesDir "Test.Notify.psm1"

    if (-not (Test-Path $notifyMod)) {
        Write-Fail "Cannot find Test.Notify.psm1 at: $notifyMod"
    } else {
        Import-Module -Name $notifyMod -Force

        $subject = "Yuruna VDE — test notification (config check)"
        $body    = @"
This is a test notification sent by Test-Config.ps1.

If you received this, your notification settings in test-config.json are working correctly.

Sent: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

        Write-Info "Sending test notification via '$notifType'..."
        try {
            Send-Notification -Config $Config -Subject $subject -Body $body
            # Send-Notification writes its own success/failure output; capture failures via exit code check.
            if ($script:FailCount -eq 0) {
                Write-Pass "Send-Notification completed (see output above for delivery confirmation)."
            }
        } catch {
            Write-Fail "Unexpected error during send: $_"
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray
$color = if ($script:FailCount -gt 0) { "Red" } elseif ($script:WarnCount -gt 0) { "Yellow" } else { "Green" }
Write-Host ("  PASS: {0,3}   WARN: {1,3}   FAIL: {2,3}" -f $script:PassCount, $script:WarnCount, $script:FailCount) -ForegroundColor $color
Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray

exit $(if ($script:FailCount -gt 0) { 1 } else { 0 })
