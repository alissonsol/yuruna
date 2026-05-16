<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456709
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
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
    Validates test.config.yml plus the test/extension/* configs and
    sends a smoke-test notification to confirm transports work.

.DESCRIPTION
    Checks that test.config.yml exists and is well-formed, validates
    the per-area extension configs (authentication, notification) under
    test/extension/, probes Resend reachability, and finally fires a
    'config.smoke' notification. The smoke event has its own subscriber
    list (separate from cycle.failure) so this validator does not spam
    real failure recipients.

.PARAMETER ConfigPath
    Path to the config file. Defaults to test/test.config.yml next to this script.

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
if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }
$TemplatePath        = Join-Path $TestRoot "test.config.yml.template"
$ExtensionRoot       = Join-Path $TestRoot "extension"
$SchemasRoot         = Join-Path $TestRoot "schemas"
$NotificationCfgPath = Join-Path $ExtensionRoot "notification/notification.transports.yml"
$NotificationTmplPath = Join-Path $ExtensionRoot "notification/notification.transports.yml.template"

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

# Best-effort schema validation. Test-Json (PS 7.4+) understands JSON
# Schema; we feed it the YAML config and schema converted back to JSON
# so the same validator works for both. When Test-Json is unavailable
# we fall back to a parse-only check so the validator still surfaces
# malformed YAML. We never block the cycle on missing schema tooling --
# only on actual content errors.
function Test-AgainstSchema {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    if (-not (Test-Path $YamlPath))   { Write-Fail "${Label}: file not found ($YamlPath)"; return }
    if (-not (Test-Path $SchemaPath)) { Write-Warn "${Label}: schema not found ($SchemaPath)"; return }
    try {
        $doc = Get-Content -Raw $YamlPath | ConvertFrom-Yaml -Ordered
    } catch {
        Write-Fail "${Label}: YAML parse error -- $($_.Exception.Message)"; return
    }
    $hasTestJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($hasTestJson) {
        try {
            $schemaJson = Get-Content -Raw $SchemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 20
            $docJson    = $doc | ConvertTo-Json -Depth 20
            if (Test-Json -Json $docJson -Schema $schemaJson -ErrorAction Stop) {
                Write-Pass "${Label}: schema-valid ($YamlPath)"
            } else {
                Write-Fail "${Label}: schema-invalid"
            }
        } catch {
            Write-Fail "${Label}: schema validation failed -- $($_.Exception.Message)"
        }
    } else {
        Write-Pass "${Label}: parse-only check passed (Test-Json unavailable; schema not enforced)"
    }
}

# ── Section 1: Config file ────────────────────────────────────────────────────

Write-Section "Config file"

if (-not (Test-Path $ConfigPath)) {
    Write-Fail "Config file not found: $ConfigPath"
    if (Test-Path $TemplatePath) {
        Write-Info "To create it, run:"
        Write-Info "  cp test/test.config.yml.template test/test.config.yml"
        Write-Info "Then edit test/test.config.yml with your notification settings."
    } else {
        Write-Info "Template not found either ($TemplatePath). Check your repository."
    }
    exit 1
}
Write-Pass "Config file found: $ConfigPath"

# ── Section 2: YAML parsing ───────────────────────────────────────────────────

Write-Section "YAML structure"

try {
    $Config = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered
    Write-Pass "YAML is valid and parsed successfully."
} catch {
    Write-Fail "YAML parse error: $_"
    Write-Info "Open test.config.yml and fix the syntax error above."
    exit 1
}

# ── Section 3: Host requirements (quick) ─────────────────────────────────────
# Imports Test.Host.psm1 and runs the same fast pre-flight that
# operator-facing helpers (Remove-TestVMFiles.ps1, ...) call: detects
# the host type and verifies the absolute minimum (Administrator +
# vmms on Hyper-V, virsh + /dev/kvm on Ubuntu, UTM.app + utmctl on
# macOS). The pointer Write-Information inside Test-HostRequirement
# is suppressed here because THIS script IS the deeper check it would
# otherwise advertise.

Write-Section "Host requirements (quick)"

$ModulesDir  = Join-Path $TestRoot "modules"
$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
$HostType    = $null
if (-not (Test-Path $hostModPath)) {
    Write-Fail "Test.Host.psm1 not found at: $hostModPath"
} else {
    Import-Module -Name $hostModPath -Force -Global
    $HostType = Get-HostType
    if (-not $HostType) {
        Write-Fail "Could not detect host type (unsupported platform)."
    } else {
        # Auto-relaunch under sg libvirt on host.ubuntu.kvm when this
        # shell's group set is stale. Most of Test-Config's later probes
        # (libvirt VM listing, host-feature checks) need libvirt-socket
        # access. No-op on other hosts / fresh shells.
        Invoke-LibvirtGroupReExecIfNeeded -HostType $HostType -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
        Write-Pass "Host type detected: $HostType"
        if (Test-HostRequirement -HostType $HostType -InformationAction SilentlyContinue) {
            Write-Pass "Host requirements quick check passed."
        } else {
            Write-Fail "Host requirements quick check failed (see warnings above)."
        }
    }
}

# ── Section 4: Host capacity ─────────────────────────────────────────────────
# RAM + CPU. Below the per-platform threshold = WARN (the harness still
# runs but risks OOM kills inside guests / slow OCR). The 16 GiB and
# 4-core thresholds match the "three concurrent 2-vCPU/4 GiB guests + an
# OCR worker on the host" calibration the cycle is sized for.

Write-Section "Host capacity"

try {
    $ramGiB     = $null
    $logicalCpu = $null
    $cpuModel   = ''
    if ($IsWindows) {
        $cs   = Get-CimInstance Win32_ComputerSystem
        $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
        $ramGiB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $logicalCpu = [int]$cs.NumberOfLogicalProcessors
        $cpuModel   = "$($cpu.Name)".Trim()
    } elseif ($IsLinux) {
        $memKb      = (Select-String -Path /proc/meminfo -Pattern '^MemTotal:\s+(\d+)' | Select-Object -First 1).Matches[0].Groups[1].Value
        $ramGiB     = [math]::Round([int64]$memKb * 1KB / 1GB, 1)
        $logicalCpu = (& nproc 2>$null) -as [int]
        $cpuModel   = ((Select-String -Path /proc/cpuinfo -Pattern '^model name\s*:\s*(.+)$' | Select-Object -First 1).Matches[0].Groups[1].Value).Trim()
    } elseif ($IsMacOS) {
        $memBytes   = (& sysctl -n hw.memsize)  -as [int64]
        $ramGiB     = [math]::Round($memBytes / 1GB, 1)
        $logicalCpu = (& sysctl -n hw.logicalcpu) -as [int]
        $cpuModel   = (& sysctl -n machdep.cpu.brand_string).Trim()
    }
    if ($null -ne $ramGiB) {
        if ($ramGiB -lt 16) {
            Write-Warn "RAM = ${ramGiB} GiB -- below 16 GiB calibration; consider running fewer guests in parallel."
        } else {
            Write-Pass "RAM = ${ramGiB} GiB."
        }
    }
    if ($null -ne $logicalCpu -and $logicalCpu -gt 0) {
        if ($logicalCpu -lt 4) {
            Write-Warn "Logical CPUs = $logicalCpu -- below 4-core calibration; cycles will be slow."
        } else {
            Write-Pass "Logical CPUs = $logicalCpu ($cpuModel)."
        }
    }
} catch {
    Write-Warn "Could not read host capacity: $($_.Exception.Message)"
}

# ── Section 5: Host-specific feature state ───────────────────────────────────
# Deeper, host-type-specific verification beyond the "command/service
# exists" gate in Test-HostRequirement: Hyper-V feature state (DISM)
# on Windows, libvirtd active + qemu installed on Linux, UTM helper
# installed on macOS. Catches "Hyper-V is half-enabled, reboot pending"
# (memory: dism_enable_pending_trap) before a cycle hits it.

Write-Section "Host-specific feature state"

switch ($HostType) {
    'host.windows.hyper-v' {
        try {
            $featureLine = & dism.exe /online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1 |
                Select-String -Pattern '^\s*State\s*:\s*(.+)$' |
                Select-Object -First 1
            if ($featureLine) {
                $state = $featureLine.Matches[0].Groups[1].Value.Trim()
                if ($state -eq 'Enabled') {
                    Write-Pass "Microsoft-Hyper-V-All feature state = Enabled."
                } else {
                    Write-Fail "Microsoft-Hyper-V-All feature state = $state. Enable from elevated PowerShell: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All  (then reboot)."
                }
            } else {
                Write-Warn "DISM did not return a Hyper-V feature state (DISM.exe needs Administrator to query feature state; the Section 3 quick check above will already have flagged elevation if that's the cause)."
            }
        } catch {
            Write-Warn "DISM Hyper-V feature query failed: $($_.Exception.Message)"
        }
        $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if ($vmms -and $vmms.Status -eq 'Running') {
            Write-Pass "Hyper-V vmms service: Running."
        } else {
            $vmmsState = if ($vmms) { "$($vmms.Status)" } else { 'not installed' }
            Write-Fail "Hyper-V vmms service: $vmmsState."
        }
    }
    'host.ubuntu.kvm' {
        if (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue) {
            Write-Pass "qemu-system-x86_64 found on PATH."
        } else {
            Write-Fail "qemu-system-x86_64 not found. Install with: sudo apt install qemu-kvm"
        }
        $libvirtd = (& systemctl is-active libvirtd 2>$null)
        if ("$libvirtd".Trim() -eq 'active') {
            Write-Pass "libvirtd: active."
        } else {
            Write-Fail "libvirtd: $libvirtd. Start with: sudo systemctl start libvirtd"
        }
        if (Test-Path '/dev/kvm') {
            Write-Pass "/dev/kvm present."
        } else {
            Write-Fail "/dev/kvm missing. Enable VT-x/SVM in firmware and load the kvm module."
        }
    }
    'host.macos.utm' {
        if (Test-Path '/Applications/UTM.app') {
            Write-Pass "UTM.app installed."
        } else {
            Write-Fail "UTM.app missing -- install from https://mac.getutm.app"
        }
        if (Get-Command utmctl -ErrorAction SilentlyContinue) {
            Write-Pass "utmctl reachable on PATH."
        } else {
            Write-Fail "utmctl missing on PATH -- symlink from /Applications/UTM.app/Contents/MacOS/utmctl"
        }
    }
}

# ── Section 6: Framework / project staleness ─────────────────────────────────
# git fetch + compare HEAD to upstream. WARN (not FAIL) when the local
# clone is behind: the harness can still run, but its runner / index.html
# is older than what landed on main. Repeat for the project clone when
# one exists under <RepoRoot>/project/ (Update-ProjectClone path).

Write-Section "Framework / project staleness"

$RepoRoot = Split-Path -Parent $TestRoot

function Test-RepoFreshness {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path (Join-Path $Path '.git'))) {
        Write-Warn "${Label}: not a git working tree ($Path) -- skipping freshness check."
        return
    }
    try {
        $null = & git -C $Path fetch --quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "${Label}: git fetch failed (offline?); cannot determine staleness."
            return
        }
        $local  = (& git -C $Path rev-parse HEAD 2>$null).Trim()
        $remote = (& git -C $Path rev-parse '@{u}' 2>$null).Trim()
        if (-not $remote) {
            Write-Info "${Label}: no upstream tracking branch -- skipping ahead/behind."
            return
        }
        if ($local -eq $remote) {
            Write-Pass "${Label}: up to date with $remote."
            return
        }
        $behind = (& git -C $Path rev-list --count "$local..$remote" 2>$null).Trim()
        $ahead  = (& git -C $Path rev-list --count "$remote..$local" 2>$null).Trim()
        if ([int]$behind -gt 0 -and [int]$ahead -eq 0) {
            Write-Warn "${Label}: $behind commit(s) behind upstream -- 'git pull --ff-only' before next cycle."
        } elseif ([int]$ahead -gt 0 -and [int]$behind -eq 0) {
            Write-Pass "${Label}: $ahead commit(s) ahead of upstream (unpushed local work)."
        } else {
            Write-Warn "${Label}: diverged ($ahead ahead, $behind behind). Rebase or merge manually."
        }
    } catch {
        Write-Warn "${Label}: freshness check threw -- $($_.Exception.Message)"
    }
}

Test-RepoFreshness -Label "framework ($RepoRoot)" -Path $RepoRoot

$projectClone = Join-Path $RepoRoot 'project'
if (Test-Path (Join-Path $projectClone '.git')) {
    Test-RepoFreshness -Label "project ($projectClone)" -Path $projectClone
} else {
    Write-Info "project/ not present under framework root -- in-tree project path (no clone to check)."
}

# ── Section 7: GitHub connectivity ───────────────────────────────────────────
# DNS + TCP probes of github.com:443. Surfaces a bad network state HERE
# rather than later when Invoke-GitPull retries inside a running cycle.

Write-Section "GitHub connectivity"

try {
    $resolved = [System.Net.Dns]::GetHostAddresses("github.com")
    Write-Pass "DNS resolved 'github.com' -> $($resolved[0].IPAddressToString)"
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect("github.com", 443, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(5000, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            Write-Pass "TCP connection to github.com:443 succeeded."
        } else {
            Write-Fail "TCP connection to github.com:443 timed out -- check firewall / VPN / captive portal."
        }
        $tcp.Close()
    } catch {
        Write-Fail "TCP connection to github.com:443 failed: $($_.Exception.Message)"
    }
} catch {
    Write-Fail "DNS resolution failed for 'github.com': $($_.Exception.Message)"
}

# ── Section 8: Top-level fields ───────────────────────────────────────────────

Write-Section "Top-level settings"

if ($Config.Contains("notification")) {
    Write-Pass "'notification' block is present."
} else {
    Write-Fail "'notification' block is missing."
}

if ($Config.vmImage -is [System.Collections.IDictionary] -and $Config.vmImage.Contains("alwaysRedownload")) {
    Write-Pass "'vmImage.alwaysRedownload' = $($Config.vmImage.alwaysRedownload)"
} else {
    Write-Warn "'vmImage.alwaysRedownload' not set — defaults to false."
}

if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains("testVmNamePrefix")) {
    Write-Pass "'vmStart.testVmNamePrefix' = '$($Config.vmStart.testVmNamePrefix)'"
} else {
    Write-Warn "'vmStart.testVmNamePrefix' not set — defaults to 'test-'."
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("recentDisplayCount")) {
    $rdc = [int]$Config.testCycle.recentDisplayCount
    if ($rdc -gt 0) { Write-Pass "'testCycle.recentDisplayCount' = $rdc" }
    else            { Write-Warn "'testCycle.recentDisplayCount' is $rdc — should be a positive integer." }
} else {
    Write-Warn "'testCycle.recentDisplayCount' not set — defaults to 30."
}

if ($Config.Contains("statusServer")) {
    $ss = $Config.statusServer
    Write-Pass "'statusServer' block present (isEnabled=$($ss.isEnabled), port=$($ss.port))."
} else {
    Write-Warn "'statusServer' not set — status HTTP server will be disabled."
}

if ($Config.Contains("hostSshServer")) {
    $hss = $Config.hostSshServer
    if ($hss -is [System.Collections.IDictionary] -and $hss.Contains('enabled')) {
        Write-Pass "'hostSshServer.enabled' = $($hss.enabled) (applied each cycle via the host-ssh-server extension)."
    } else {
        Write-Warn "'hostSshServer' block is present but missing 'enabled' boolean — runner will leave SSH state alone."
    }
} else {
    Write-Warn "'hostSshServer' not set — runner will not touch host SSH state. Add 'hostSshServer:\n  enabled: false' to opt in to config-driven control."
}

if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.Contains("frameworkUrl")) {
    Write-Pass "'repositories.frameworkUrl' = '$($Config.repositories.frameworkUrl)'"
} else {
    Write-Warn "'repositories.frameworkUrl' not set — status page commit links may not work, and the failure-pause break-out trigger that watches the framework repo will be a no-op."
}

if ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains("shouldStopOnFailure")) {
    Write-Pass "'testCycle.shouldStopOnFailure' = $($Config.testCycle.shouldStopOnFailure)"
} else {
    Write-Warn "'testCycle.shouldStopOnFailure' not set — defaults to false (continues on failure)."
}

# Abort here if notification block is missing; nothing more to check.
if (-not $Config.Contains("notification")) { exit 1 }

$notif = $Config.notification

# Soft migration: surface legacy keys that have moved to notification.transports.yml.
if ($notif.Contains('toEmailAddress') -and (Test-IsSet $notif.toEmailAddress)) {
    Write-Warn "notification.toEmailAddress is set in test.config.yml -- this key has moved to test/extension/notification/notification.transports.yml (subscribers list). Move it manually before the next cycle."
}
if ($Config.Contains('secrets') -and $Config.secrets -is [System.Collections.IDictionary] -and $Config.secrets.Contains('resend')) {
    Write-Warn "secrets.resend is set in test.config.yml -- this block has moved to test/extension/notification/notification.transports.yml (transports.resend). Move it manually before the next cycle."
}

# ── Section 9: Extension configs ─────────────────────────────────────────────

Write-Section "Extension configs"

Test-AgainstSchema -Label "authentication/authentication.config.yml" `
    -YamlPath   (Join-Path $ExtensionRoot "authentication/authentication.config.yml") `
    -SchemaPath (Join-Path $SchemasRoot   "extension-config.schema.yml")

Test-AgainstSchema -Label "notification/notification.config.yml" `
    -YamlPath   (Join-Path $ExtensionRoot "notification/notification.config.yml") `
    -SchemaPath (Join-Path $SchemasRoot   "extension-config.schema.yml")

if (-not (Test-Path $NotificationCfgPath)) {
    if (Test-Path $NotificationTmplPath) {
        Write-Warn "notification.transports.yml missing -- copy from notification.transports.yml.template and populate before the next cycle: $NotificationTmplPath -> $NotificationCfgPath"
    } else {
        Write-Fail "notification.transports.yml missing and no template found at $NotificationTmplPath"
    }
} else {
    Test-AgainstSchema -Label "notification.transports.yml" `
        -YamlPath   $NotificationCfgPath `
        -SchemaPath (Join-Path $SchemasRoot "notification.transports.schema.yml")
}

$VaultPath = Join-Path $ExtensionRoot "authentication/vault.yml"
if (Test-Path $VaultPath) {
    Test-AgainstSchema -Label "vault.yml" `
        -YamlPath   $VaultPath `
        -SchemaPath (Join-Path $SchemasRoot "vault.schema.yml")
} else {
    Write-Info "vault.yml not present (expected; created on cycle start)."
}

# ── Section 10: Resend transport settings ────────────────────────────────────

Write-Section "Resend transport settings"

$resend = $null
if (Test-Path $NotificationCfgPath) {
    try {
        $notifCfg = Get-Content -Raw $NotificationCfgPath | ConvertFrom-Yaml -Ordered
        if ($notifCfg.Contains('transports') -and $notifCfg.transports.Contains('resend')) {
            $resend = $notifCfg.transports.resend
        }
    } catch {
        Write-Fail "notification.transports.yml parse error: $($_.Exception.Message)"
    }
}

if (-not $resend) {
    Write-Warn "transports.resend not configured in notification.transports.yml -- email transport will warn at runtime."
} else {
    if (Test-IsSet $resend.apiKey) {
        Write-Pass "transports.resend.apiKey is set (not shown)."
        if (-not "$($resend.apiKey)".StartsWith("re_")) {
            Write-Warn "transports.resend.apiKey does not start with 're_' -- Resend API keys typically begin with 're_'."
        }
    } else {
        Write-Fail "transports.resend.apiKey is not set. Get your API key at https://resend.com/api-keys"
    }

    if (Test-IsSet $resend.fromEmail) {
        Write-Pass "transports.resend.fromEmail = '$($resend.fromEmail)'"
    } else {
        Write-Fail "transports.resend.fromEmail is not set. Example: 'Yuruna <notifications@yourdomain.com>'"
    }
}

# Abort if any FAIL was recorded before network checks.
if ($script:FailCount -gt 0) {
    Write-Output "`nFix the errors above before testing network connectivity."
    exit 1
}

# ── Section 11: Resend API connectivity ──────────────────────────────────────

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

# ── Section 12: Live smoke notification ──────────────────────────────────────

Write-Section "Live smoke notification (config.smoke)"

if ($SkipSend) {
    Write-Warn "Skipping live send (-SkipSend was specified)."
} elseif ($script:FailCount -gt 0) {
    Write-Warn "Skipping live send because earlier checks failed."
} else {
    $notifyMod  = Join-Path $ModulesDir "Test.Notify.psm1"
    if (-not (Test-Path $notifyMod)) {
        Write-Fail "Cannot find Test.Notify.psm1 at: $notifyMod"
    } else {
        Import-Module -Name $notifyMod -Force

        $message = "Yuruna -- configuration smoke test (config.smoke)"
        $note    = @"
This is a smoke notification fired by Test-Config.ps1 against the
'config.smoke' event code. If you received it, the active notification
extensions and their transports are wired correctly.

Add subscribers under subscribers.config.smoke in
test/extension/notification/notification.transports.yml to receive these.
With no subscribers, this run is a verbose no-op (which is fine).

Sent: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")) UTC
"@

        Write-Info "Dispatching 'config.smoke' to the active notification extensions..."
        try {
            Send-Notification -EventCode 'config.smoke' -EventMessage $message -EventNote $note
            Write-Pass "Send-Notification dispatch completed without error."
            Write-Info "Empty subscribers list is normal -- check subscribers.config.smoke if you expected delivery."
        } catch {
            Write-Fail "Send-Notification failed: $_"
            Write-Info "Verify your transports.resend.apiKey and fromEmail in notification.transports.yml"
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Output ""
Write-Output "─────────────────────────────────────────"
Write-Output ("  PASS: {0,3}   WARN: {1,3}   FAIL: {2,3}" -f $script:PassCount, $script:WarnCount, $script:FailCount)
Write-Output "─────────────────────────────────────────"

exit ($script:FailCount -gt 0 ? 1 : 0)
