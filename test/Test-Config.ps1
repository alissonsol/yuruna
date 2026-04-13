<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456709
.AUTHOR Alisson Sol
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

#requires -version 7

<#
.SYNOPSIS
    Validates test-config.json and sends a test notification to confirm it works.

.DESCRIPTION
    Checks that test-config.json exists and is well-formed, validates all required
    fields for Resend API notification, probes network connectivity, and finally
    sends a live test notification.
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

function Write-Pass  { param([string]$msg) Write-Output "  [PASS] $msg"; $script:PassCount++ }
function Write-Fail  { param([string]$msg) Write-Output "  [FAIL] $msg"; $script:FailCount++ }
function Write-Warn  { param([string]$msg) Write-Output "  [WARN] $msg"; $script:WarnCount++ }
function Write-Info  { param([string]$msg) Write-Output "        $msg" }
function Write-Section { param([string]$msg) Write-Output "`n=== $msg ===" }

# Returns $true when a value is a non-empty string, $false otherwise.
function Test-IsSet { param($v) return ($null -ne $v -and "$v".Trim() -ne "") }

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

if ($Config.ContainsKey("repoUrl")) {
    Write-Pass "'repoUrl' = '$($Config.repoUrl)'"
} else {
    Write-Warn "'repoUrl' not set — status page commit links may not work."
}

if ($Config.ContainsKey("stopOnFailure")) {
    Write-Pass "'stopOnFailure' = $($Config.stopOnFailure)"
} else {
    Write-Warn "'stopOnFailure' not set — defaults to false (continues on failure)."
}

# Abort here if notification block is missing; nothing more to check.
if (-not $Config.ContainsKey("notification")) { exit 1 }

$notif = $Config.notification

# ── Section 4: Resend API settings ───────────────────────────────────────────

Write-Section "Resend API settings"

if (Test-IsSet $notif.toAddress) { Write-Pass "notification.toAddress = '$($notif.toAddress)'" }
else                         { Write-Fail "notification.toAddress is not set." }

$resend = $notif.resend

if (-not $resend) {
    Write-Fail "'notification.resend' block is missing."
    exit 1
}

Write-Pass "'notification.resend' block is present."

if (Test-IsSet $resend.apiKey) {
    Write-Pass "resend.apiKey is set (not shown)."
    if (-not "$($resend.apiKey)".StartsWith("re_")) {
        Write-Warn "resend.apiKey does not start with 're_' — Resend API keys typically begin with 're_'."
    }
} else {
    Write-Fail "resend.apiKey is not set. Get your API key at https://resend.com/api-keys"
}

if (Test-IsSet $resend.from) {
    Write-Pass "resend.from = '$($resend.from)'"
} else {
    Write-Fail "resend.from is not set. Example: 'Yuruna VDE <notifications@yourdomain.com>'"
}

# Abort if any FAIL was recorded before network checks.
if ($script:FailCount -gt 0) {
    Write-Output "`nFix the errors above before testing network connectivity."
    exit 1
}

# ── Section 5: Resend API connectivity ───────────────────────────────────────

Write-Section "Resend API connectivity"

try {
    $resolved = [System.Net.Dns]::GetHostAddresses("api.resend.com")
    Write-Pass "DNS resolved 'api.resend.com' -> $($resolved[0].IPAddressToString)"
} catch {
    Write-Fail "DNS resolution failed for 'api.resend.com': $_"
    Write-Info "Check that DNS is available and api.resend.com is reachable."
    exit 1
}

try {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $ar  = $tcp.BeginConnect("api.resend.com", 443, $null, $null)
    $ok  = $ar.AsyncWaitHandle.WaitOne(5000, $false)
    if ($ok -and $tcp.Connected) {
        $tcp.EndConnect($ar)
        Write-Pass "TCP connection to api.resend.com:443 succeeded."
    } else {
        Write-Fail "TCP connection to api.resend.com:443 timed out."
        Write-Info "Verify that no firewall is blocking outbound HTTPS."
    }
    $tcp.Close()
} catch {
    Write-Fail "TCP connection to api.resend.com:443 failed: $_"
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

Sent: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")) UTC
"@

        Write-Info "Sending test notification via Resend API..."
        try {
            Send-Notification -Config $Config -Subject $subject -Body $body
            Write-Pass "Send-Notification completed successfully."
        } catch {
            Write-Fail "Send-Notification failed: $_"
            Write-Info "Verify your Resend API key and 'from' domain at https://resend.com"
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Output ""
Write-Output "─────────────────────────────────────────"
Write-Output ("  PASS: {0,3}   WARN: {1,3}   FAIL: {2,3}" -f $script:PassCount, $script:WarnCount, $script:FailCount)
Write-Output "─────────────────────────────────────────"

exit ($script:FailCount -gt 0 ? 1 : 0)
