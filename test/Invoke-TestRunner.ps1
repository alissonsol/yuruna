<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456707
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
    Continuous VDE test cycle. Creates guest VMs per test-config.json,
    runs their test sequences, loops until a failure.

.DESCRIPTION
    Primary harness entry point. Each cycle:
      1. git pull (unless -NoGitPull)
      2. re-read test-config.json
      3. refresh base images if stale
      4. detect the caching proxy (local VM or remote IP)
      5. for each guest in guestOrder: cleanup → New-VM → Start-VM →
         Verify-VM → Invoke-PoolTest
      6. log, pause, next cycle
      7. on first failure: leave the VM running, notify, exit

    Full config schema, guest ordering, and notification setup live in
    test/README.md. This help block only covers the command line and
    the most load-bearing environment variables.

    ENVIRONMENT VARIABLES:

    $Env:YURUNA_CACHING_PROXY_IP — point the runner at a remote
      squid-cache instead of looking for a local VM. When set, guest
      New-VM.ps1 invocations inherit the remote URL, fetch the CA from
      http://<ip>/yuruna-squid-ca.crt, and wire apt to http://<ip>:3128
      (HTTP) + http://<ip>:3129 (HTTPS). The remote host must run the
      same caching proxy image; see docs/caching.md for the image itself
      and test/CachingProxy.md for the harness-facing override.
      Un-set or empty to fall back to local discovery.

      Validate a candidate cache BEFORE launching a full cycle with:
          $Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
          pwsh test/Test-CachingProxy.ps1
      That script TCP-probes :3128, :3129, :80, :3000 and fetches the
      CA cert — PASS / FAIL / WARN per check, exit 1 if any required
      port fails.

.PARAMETER ConfigPath
    Path to test-config.json. Defaults to test/test-config.json next to
    this script.

.PARAMETER NoGitPull
    Skip the `git pull` at the start of each cycle. Useful during local
    development when you want to iterate without pushing.

.PARAMETER NoServer
    Skip launching the built-in HTTP status server on port 8080.

.PARAMETER NoExtensionOutput
    Suppress extension script stdout/stderr in the runner's console.
    Extensions still run and their output is written to the log file.

.PARAMETER CycleDelaySeconds
    Pause between cycles. Default 30.

.PARAMETER debug_mode
    Set to $true to raise $DebugPreference to Continue.

.PARAMETER verbose_mode
    Set to $true to raise $VerbosePreference to Continue.

.EXAMPLE
    # Local squid-cache (previously brought up by test/Start-CachingProxy.ps1)
    pwsh test/Invoke-TestRunner.ps1

.EXAMPLE
    # Remote squid-cache at 10.0.0.5 — no local VM needed.
    $Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
    pwsh test/Test-CachingProxy.ps1          # preflight
    pwsh test/Invoke-TestRunner.ps1

.EXAMPLE
    # Iterate locally without pushing / without the status server.
    pwsh test/Invoke-TestRunner.ps1 -NoGitPull -NoServer
#>

# Global variable is the cross-module channel with yuruna-log.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoServer,
    [switch]$NoExtensionOutput,
    [int]$CycleDelaySeconds    = 30,
    [bool]$debug_mode          = $false,
    [bool]$verbose_mode        = $false
)

$global:InformationPreference = "Continue"

$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"
if ($debug_mode) {
    $global:DebugPreference = "Continue"
}
if ($verbose_mode) {
    $global:VerbosePreference = "Continue"
}

# === Resolve paths ===
# Track/log dirs come from Test.TrackDir / Test.LogDir; override with
# $env:YURUNA_TRACK_DIR / $env:YURUNA_LOG_DIR. Defaults: test/status/track/
# and test/status/log/, both served by the status HTTP server.
$TestRoot       = $PSScriptRoot
$RepoRoot       = Split-Path -Parent $TestRoot
$VdeRoot        = Join-Path $RepoRoot "vde"
$StatusDir      = Join-Path $TestRoot "status"
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ModulesDir     = Join-Path $TestRoot "modules"
$ExtensionsDir  = Join-Path $TestRoot "extensions"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"

Import-Module (Join-Path $ModulesDir "Test.TrackDir.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1")   -Force
$null = Initialize-YurunaTrackDir
$null = Initialize-YurunaLogDir
$StatusFile = Join-Path $env:YURUNA_TRACK_DIR "status.json"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }
$TemplatePath = Join-Path $TestRoot "test-config.json.template"

# === Single-instance guard ===
# If another Invoke-TestRunner.ps1 is running, stop it and wipe stranded
# test VMs. Two instances race on VM names and shared status files,
# leaving VMs stuck in Starting/Stopping state.
#
# YURUNA_RUNNER_RELAUNCH marks the source-change relaunch branch below —
# that branch spawns a child Invoke-TestRunner.ps1; don't let the child
# treat its own parent as a competitor.
$RunnerPidFile = Join-Path $env:YURUNA_TRACK_DIR "runner.pid"
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1' -and (Test-Path $RunnerPidFile)) {
    $existingPid = 0
    # Unreadable/malformed/missing pidfile treated as "no prior runner";
    # Get-Process 0 returns null so the branch is a safe no-op.
    try { $existingPid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $existingPid = 0 }
    if ($existingPid -gt 0 -and $existingPid -ne $PID -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        # Verify the PID is an Invoke-TestRunner.ps1 — don't kill a process
        # that recycled this PID. Windows uses CIM; macOS/Linux use
        # /bin/ps (path-qualified so PSSA doesn't confuse it with the `ps`
        # alias for Get-Process — we need `-o args=` which Get-Process
        # can't produce portably on Unix).
        $cmd = $null
        if ($IsWindows) {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$existingPid" -ErrorAction SilentlyContinue).CommandLine
        } elseif ($IsMacOS -or $IsLinux) {
            $cmd = & '/bin/ps' -p $existingPid -o args= 2>$null
        }
        if ($cmd -and $cmd -match 'Invoke-TestRunner\.ps1') {
            Write-Output ""
            Write-Output "============================================="
            Write-Output "  Another Invoke-TestRunner.ps1 is running"
            Write-Output "  PID:     $existingPid"
            Write-Output "  Action:  stopping it and running"
            Write-Output "           Remove-TestVMFiles.ps1 before start"
            Write-Output "============================================="
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            # Wait for the old process to die so its Hyper-V/UTM VM ops
            # can't race with ours.
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 500
            }
            try {
                $cleanup = Join-Path $TestRoot "Remove-TestVMFiles.ps1"
                if (Test-Path $cleanup) {
                    # Use 'test-' (template default): test-config.json
                    # hasn't been merged yet, so we can't read a user
                    # override. If the user picked a custom prefix this
                    # cleanup is a no-op — same as if the guard didn't run.
                    & pwsh -NoProfile -File $cleanup -Prefix 'test-'
                }
            } catch {
                Write-Warning "Remove-TestVMFiles.ps1 failed during single-instance takeover: $_"
            }
        } else {
            Write-Warning "Stale runner.pid: PID $existingPid is not an Invoke-TestRunner.ps1 process. Ignoring."
        }
    }
    Remove-Item $RunnerPidFile -Force -ErrorAction SilentlyContinue
}
# Record our PID regardless of relaunch. On relaunch the child overwrites
# the parent's entry — deliberate: the child does the real work and should
# own the lock.
$PID | Set-Content -Path $RunnerPidFile -Encoding ascii

# === Publish debug/verbose preferences so child processes inherit them ===
$env:YURUNA_DEBUG   = $debug_mode   ? '1' : '0'
$env:YURUNA_VERBOSE = $verbose_mode ? '1' : '0'

# === Import all modules (suppress engine verbose noise during imports) ===
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "yuruna-log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

foreach ($mod in @("Test.Host", "Test.Status", "Test.Notify", "Test.Get-Image", "Test.Provenance", "Test.New-VM", "Test.Start-VM", "Test.Install-OS", "Test.Screenshot", "Test.Invoke-PoolTest", "Test.Log", "Test.CachingProxy", "Test.PortMap")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

$global:VerbosePreference = $savedVerbose

# === Bootstrap status.json from template if missing ===
if (-not (Test-Path $StatusFile)) {
    if (Test-Path $StatusTmpl) {
        Copy-Item -Path $StatusTmpl -Destination $StatusFile
        Write-Output "Created status.json from template."
    } else {
        Write-Error "Status template not found: $StatusTmpl"; exit 1
    }
}

# === Helpers: sync test-config.json against its template ===
# Each cycle overlays the live config on the template so new template keys
# are picked up without losing user values. Rewrite to disk only when the
# merge differs from disk outside the 'secrets' subtree (credentials
# always diverge from template blanks; including them would churn the
# file every cycle).

# Overlay $Current onto $Template. Template shape wins (which keys exist);
# current values win for overlapping scalars/arrays. Keys only in $Current
# are dropped — template is the schema source of truth. Keys emitted
# alphabetically at every nesting level so regenerated test-config.json
# is stable regardless of the template's own key ordering.
function ConvertTo-MergedHashtable {
    param($Template, $Current)

    if ($Template -isnot [System.Collections.IDictionary]) { return $Template }

    $result = [ordered]@{}
    foreach ($key in ($Template.Keys | Sort-Object)) {
        $tVal = $Template[$key]
        $hasCurrent = ($Current -is [System.Collections.IDictionary]) -and $Current.Contains($key)
        if ($tVal -is [System.Collections.IDictionary]) {
            $cVal = $hasCurrent ? $Current[$key] : $null
            $result[$key] = ConvertTo-MergedHashtable -Template $tVal -Current $cVal
        } elseif ($hasCurrent) {
            $result[$key] = $Current[$key]
        } else {
            $result[$key] = $tVal
        }
    }
    return $result
}

# Shallow clone of $Config without top-level 'secrets' for diff comparison.
function Copy-HashtableWithoutSecretNode {
    param($Config)
    if ($Config -isnot [System.Collections.IDictionary]) { return $Config }
    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        if ($key -eq 'secrets') { continue }
        $copy[$key] = $Config[$key]
    }
    return $copy
}

function Update-TestConfigFromTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string]$TemplatePath
    )

    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "Template not found: $TemplatePath — loading config as-is."
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable)
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Information "Config not found: $ConfigPath — bootstrapping from template." -InformationAction Continue
        Copy-Item -Path $TemplatePath -Destination $ConfigPath
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable)
    }

    $template = Get-Content -Raw $TemplatePath | ConvertFrom-Json -AsHashtable
    $current  = Get-Content -Raw $ConfigPath   | ConvertFrom-Json -AsHashtable

    # TODO: remove this legacy shim once all active checkouts have migrated.
    # notification.resend.{apiKey,from} used to live under notification;
    # move values into secrets.resend so the merge (which drops
    # template-orphan keys) doesn't lose them.
    if ($current -is [System.Collections.IDictionary] -and
        $current.Contains('notification') -and
        $current['notification'] -is [System.Collections.IDictionary] -and
        $current['notification'].Contains('resend')) {
        $legacy = $current['notification']['resend']
        if (-not $current.Contains('secrets') -or $current['secrets'] -isnot [System.Collections.IDictionary]) {
            $current['secrets'] = [ordered]@{}
        }
        if (-not $current['secrets'].Contains('resend') -or $current['secrets']['resend'] -isnot [System.Collections.IDictionary]) {
            $current['secrets']['resend'] = [ordered]@{}
        }
        foreach ($k in @($legacy.Keys)) {
            $existing = $current['secrets']['resend'][$k]
            if ([string]::IsNullOrEmpty("$existing")) {
                $current['secrets']['resend'][$k] = $legacy[$k]
            }
        }
        $current['notification'].Remove('resend')
        Write-Information "Migrated legacy notification.resend.* -> secrets.resend.* in $ConfigPath" -InformationAction Continue
    }

    $merged = ConvertTo-MergedHashtable -Template $template -Current $current

    # Validate keystrokeMechanism. Canonical values "GUI"/"SSH";
    # recognition is case-insensitive, value is normalized to uppercase.
    # Unrecognized values (including legacy "hypervisor") are discarded
    # and replaced with the template default. No migration.
    $validMechanisms = @('GUI', 'SSH')
    if ($merged -is [System.Collections.IDictionary] -and $merged.Contains('keystrokeMechanism')) {
        $original = "$($merged['keystrokeMechanism'])"
        $upper    = $original.ToUpperInvariant()
        if ($upper -in $validMechanisms) {
            if ($original -cne $upper) {
                $merged['keystrokeMechanism'] = $upper
            }
        } else {
            $default = "$($template['keystrokeMechanism'])"
            Write-Information "test-config.json: keystrokeMechanism='$original' not recognized — resetting to '$default'." -InformationAction Continue
            $merged['keystrokeMechanism'] = $default
        }
    }

    $mergedForDiff  = Copy-HashtableWithoutSecretNode $merged
    $currentForDiff = Copy-HashtableWithoutSecretNode $current
    $mergedJson  = $mergedForDiff  | ConvertTo-Json -Depth 20
    $currentJson = $currentForDiff | ConvertTo-Json -Depth 20

    if ($mergedJson -ne $currentJson) {
        if ($PSCmdlet.ShouldProcess($ConfigPath, "Rewrite with template overlay")) {
            Write-Information "test-config.json: applying template overlay to pick up schema changes." -InformationAction Continue
            $merged | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigPath -Encoding utf8NoBOM
        }
    }

    return $merged
}

# === Read config (syncs against template first) ===
if (-not (Test-Path $ConfigPath) -and -not (Test-Path $TemplatePath)) {
    Write-Error "Neither config nor template found. Config: $ConfigPath  Template: $TemplatePath"; exit 1
}
$Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath

# === Phase 0: Bootstrap ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit 1 }

Write-Output "Track directory: $env:YURUNA_TRACK_DIR"
Write-Output "Log directory:   $env:YURUNA_LOG_DIR"

# Proxy-cache detection lives in Test.CachingProxy.psm1 so Start-StatusServer
# shares the same probe — console banner here and the status-page banner
# (via $env:YURUNA_TRACK_DIR/caching-proxy.txt) stay in lockstep with the
# URL injected into autoinstall user-data by guest.ubuntu.desktop/New-VM.ps1.
$cachingProxyUrl = Test-CachingProxyAvailable -HostType $HostType

# Local cache detected: expose the VM's ports on the host so LAN clients
# and other machines can reach the proxy, ssl-bump listener, Apache CA
# cert, and Grafana dashboard without reaching into the VM's NAT subnet.
# Add-CachingProxyPortMap dispatches per-platform via Test.PortMap.psm1
# (netsh portproxy + firewall rule on Hyper-V; detached TcpListener
# forwarders on macOS/UTM). No cache: undo any mapping a prior cycle left.
#
# Port list @(80, 3128, 3129, 3000) MUST match Start-CachingProxy.ps1 —
# Add-CachingProxyPortMap runs Clear-AllCachingProxyPortMapping first,
# so a narrower list at either caller would tear down the other's ports.
# Local guests reach the VM directly on its NAT subnet regardless.
#
# External-cache branch: when $Env:YURUNA_CACHING_PROXY_IP is set,
# Test-CachingProxyAvailable returns the remote URL and the remote host
# serves all four ports. Guests reach it via the host's outbound NAT —
# no local portproxy/forwarder needed. Skip Add-CachingProxyPortMap and
# link the dashboard directly at the remote IP. Remove leftover mappings
# from a prior local-cache cycle so the old VM IP doesn't answer stale
# proxy requests.
#
# The "detected" word is an ANSI OSC 8 hyperlink to the Grafana dashboard
# so modern terminals (Windows Terminal, VS Code) can ctrl-click into the
# caching-proxy view. Terminals without OSC 8 drop the escapes silently —
# no regression.
if ($cachingProxyUrl) {
    $vmIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
    $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_IP
    $mapOk = $false
    $bestIp = $null
    if ($isExternal) {
        # Remote cache serves its own ports; clear any local mapping left
        # by a prior cycle, then point the dashboard at the remote.
        [void](Remove-CachingProxyPortMap)
        $mapOk = $true
        $bestIp = $vmIp
    } elseif ($vmIp) {
        $CachingProxyExposedPorts = @(80, 3128, 3129, 3000)
        $mapResult = Add-CachingProxyPortMap -VMIp $vmIp -Port $CachingProxyExposedPorts
        $mapOk = [bool]$mapResult
        $bestIp = Get-BestHostIp
        if (-not $bestIp) { $bestIp = $vmIp }  # no routable iface — fall back
    }
    if ($mapOk) {
        $dashboardUrl = "http://${bestIp}:3000/d/yuruna-squid/squid-cache-yuruna?orgId=1&from=now-2h&to=now&timezone=browser&refresh=1m"
        $esc = [char]27
        $label = if ($isExternal) { "detected (external: $vmIp)" } else { "detected" }
        $linkedDetected = "${esc}]8;;${dashboardUrl}${esc}\${label}${esc}]8;;${esc}\"
        Write-Output "Caching proxy: $linkedDetected"
    } else {
        Write-Output "Caching proxy: detected (port map failed)"
    }
} else {
    Write-Output "Caching proxy: not detected (guests will download directly from Ubuntu mirrors)"
    [void](Remove-CachingProxyPortMap)
}

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path $ModulesDir "Test.OcrEngine.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.Tesseract.psm1") -Force
$global:VerbosePreference = $savedVerbose
$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Debug "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit 1 }

$startScript = Join-Path $TestRoot "Start-StatusServer.ps1"
if ($Config.statusServer.enabled -and -not $NoServer) {
    $serverPort  = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
    & $startScript -Port $serverPort -Restart
}

# === Helper: strip everything under the top-level 'secrets' node before logging ===
function Remove-SecretsFromConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates a local in-memory hashtable used only for log redaction; no system state changes.')]
    param($Config)
    if ($Config -is [System.Collections.IDictionary] -and $Config.Contains('secrets')) {
        $node = $Config['secrets']
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in @($node.Keys)) { $node.Remove($key) }
        }
    }
}

# === Helper: copy failure artifacts to status/log for remote inspection ===
function Copy-FailureArtifactsToStatusLog {
    param([string]$VMName)
    try {
        if (-not $LogFile) { return }
        $logId = [System.IO.Path]::GetFileNameWithoutExtension($LogFile)
        $statusLogDir = [System.IO.Path]::GetDirectoryName($LogFile)
        # UTC timestamp prevents multiple failures in one run from overwriting each other
        $errorTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')

        $srcScreen = Join-Path $env:YURUNA_LOG_DIR "failure_screenshot_${VMName}.png"
        if (Test-Path $srcScreen) {
            $destName = "$logId.$errorTimestamp.failure-screenshot.png"
            $dest = Join-Path $statusLogDir $destName
            Copy-Item -Path $srcScreen -Destination $dest -Force
            Write-Output "  Failure screenshot saved: ./status/log/$destName"
            # Clickable HTML link straight to log file (bypasses proxy encoding)
            if ($global:__YurunaLogFile) {
                "  <a href=""$destName"">Failure screenshot: $destName</a>" |
                    Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
            }
        }

        $srcOcr = Join-Path $env:YURUNA_LOG_DIR "failure_ocr_${VMName}.txt"
        if (Test-Path $srcOcr) {
            $destName = "$logId.$errorTimestamp.failure-ocr.txt"
            $dest = Join-Path $statusLogDir $destName
            Copy-Item -Path $srcOcr -Destination $dest -Force
            Write-Output "  Failure OCR text saved: ./status/log/$destName"
            if ($global:__YurunaLogFile) {
                "  <a href=""$destName"">Failure OCR text: $destName</a>" |
                    Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Warning "  Could not copy failure artifacts to status/log: $_"
    }
}

# === Graceful shutdown support ===
# CancelKeyPress handler runs in a separate SessionState (Register-ObjectEvent
# -Action creates its own scope) so $script:var would not propagate back.
# Use a thread-safe dictionary so the event action and main loop share state.
$script:ShutdownState = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()
$script:ShutdownState['Requested'] = $false
$script:ActiveVMName      = $null
$script:CycleFinalized    = $true    # have Complete-Run/Stop-LogFile been called?

try {
    # Register-ObjectEvent (not [Console]::add_CancelKeyPress) so the
    # handler runs on the PowerShell pipeline thread with a runspace.
    # A raw .NET event delegate fires on a CLR thread-pool thread with
    # no runspace, causing a fatal PSInvalidOperationException
    # ("There is no Runspace available...") that kills the process and
    # prevents graceful cleanup.
    $shutdownRef = $script:ShutdownState
    # Clean up any subscriber/job left by a prior run that exited without
    # reaching the bottom-of-script Unregister-Event (Ctrl+C, error,
    # IDE-terminated). Otherwise re-running in the same shell fails with
    # "A subscriber with the source identifier ... already exists".
    Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
    Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
        -SourceIdentifier YurunaCancelKey -MessageData $shutdownRef -Action {
            $Event.SourceEventArgs.Cancel = $true
            $Event.MessageData['Requested'] = $true
            Write-Warning "Shutdown requested (Ctrl+C). Will clean up after current operation..."
        }
} catch {
    Write-Verbose "Could not register CancelKeyPress handler (non-interactive session): $_"
}

# === Source-change detection ===
# Capture mtimes so the next cycle relaunches if Invoke-TestRunner.ps1 or
# any module under test/modules is edited mid-run.
function Get-SourceFingerprint {
    param([string]$ScriptPath, [string]$ModulesDir)
    $files = @((Get-Item $ScriptPath))
    if (Test-Path $ModulesDir) {
        $files += Get-ChildItem -Path $ModulesDir -Filter *.psm1 -File -Recurse
    }
    ($files | Sort-Object FullName | ForEach-Object {
        "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)|$($_.Length)"
    }) -join "`n"
}
$script:SourceFingerprint = Get-SourceFingerprint -ScriptPath $PSCommandPath -ModulesDir $ModulesDir

# === Continuous test loop ===
$CycleCount     = 0
try {
    $prevStatus = Get-Content -Raw $StatusFile | ConvertFrom-Json
    if ($prevStatus.cycle) { $CycleCount = [int]$prevStatus.cycle }
} catch { Write-Warning "Could not read previous cycle count from status file: $_" }
$OverallPassed       = $true
$ConsecutiveCrashes  = 0
$MaxConsecutiveCrashes = 3

# === Notification gating ===
# failuresBeforeAlert : consecutive failures needed to send an alert.
# successesBeforeRearm: consecutive successes (or a fresh runner start)
#                       needed before the alert can fire again.
# State: Armed → (N failures) → Fired → (M successes) → Armed
$FailuresBeforeAlert  = [int]($Config.notification.failuresBeforeAlert  ?? 1)
$SuccessesBeforeRearm = [int]($Config.notification.successesBeforeRearm ?? 1)
$ConsecutiveFailures  = 0
$ConsecutiveSuccesses = 0
$AlertArmed           = $true   # armed on every fresh start of Invoke-TestRunner

while ($true) {
    if ($script:ShutdownState['Requested']) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    # Relaunch in a fresh process if the script or any module changed
    # on disk — the running process has sources cached in memory.
    $currentFingerprint = Get-SourceFingerprint -ScriptPath $PSCommandPath -ModulesDir $ModulesDir
    if ($currentFingerprint -ne $script:SourceFingerprint) {
        Write-Output "Source changed on disk — relaunching Invoke-TestRunner.ps1 for next cycle..."
        $pwshExe = (Get-Process -Id $PID).Path
        # Signal the child to skip the single-instance guard; otherwise
        # it would see this parent's runner.pid and kill the only process
        # we want running.
        $env:YURUNA_RUNNER_RELAUNCH = '1'
        try {
            & $pwshExe -NoLogo -File $PSCommandPath @PSBoundParameters
        } finally {
            Remove-Item Env:YURUNA_RUNNER_RELAUNCH -ErrorAction SilentlyContinue
        }
        exit $LASTEXITCODE
    }

    # Re-check host conditions each cycle — settings can revert (OS
    # update, manual change) between long-running cycles.
    if (-not (Assert-HostConditionSet -HostType $HostType)) {
        Write-Warning "Host conditions failed. Fix the reported issues and restart."
        break
    }

    $CycleCount++
    $OverallPassed  = $true
    $FailedGuest    = $null
    $FailedStep     = $null
    $FailureMessage = $null
    $script:CycleFinalized = $false
    $Warnings = [System.Collections.Generic.List[string]]::new()

  try {

    Write-Output ""
    Write-Output "============================================="
    Write-Output "  CYCLE $CycleCount"
    Write-Output "============================================="

    # --- Git pull ---
    if (-not $NoGitPull) {
        if (-not (Invoke-GitPull -RepoRoot $RepoRoot)) {
            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  ERROR: git sync failed"
            Write-Output "  Could not update from remote. Possible causes:"
            Write-Output "  - Local branch has diverged (rebase/merge manually)"
            Write-Output "  - Network connectivity issue"
            Write-Output "  - Uncommitted local changes blocking fast-forward"
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output ""
            $body = Format-FailureMessage `
                -HostType     $HostType `
                -Hostname     (hostname) `
                -GuestKey     "(bootstrap)" `
                -StepName     "GitPull" `
                -ErrorMessage "Git sync failed. Branch may have diverged, or network is unreachable." `
                -CycleId      "(not yet assigned)" `
                -GitCommit    (Get-CurrentGitCommit -RepoRoot $RepoRoot)
            Send-Notification -Config $Config `
                -Subject "Yuruna VDE Test: FAIL on $HostType / GitPull" `
                -Body    $body
            exit 1
        }
    } else {
        $Warnings.Add("Git pull was skipped (-NoGitPull).")
    }
    $GitCommit = Get-CurrentGitCommit -RepoRoot $RepoRoot

    # --- Re-read config (may have changed via git pull); sync against template ---
    try {
        $Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
    } catch {
        Write-Warning "Could not reload config after git pull, using previous config: $_"
    }

    # --- Restart status server to pick up any file/config changes ---
    if ($Config.statusServer.enabled -and -not $NoServer) {
        $serverPort = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
        & $startScript -Port $serverPort -Restart
    }

    $GuestList = Get-GuestList -Config $Config
    $Prefix = $Config.testVmNamePrefix ?? "test-"

    # Build VM name map via Get-TestVMName so any guestOrder key yields a
    # stable VM name — no hardcoded per-guest lookup needed.
    $VMNames = @{}
    foreach ($GuestKey in $GuestList) {
        $VMNames[$GuestKey] = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
    }

    # --- Derive step list from available extensions and screenshot schedules ---
    $BaseSteps = @("New-VM", "Start-VM", "Install-OS", "Verify-VM")
    $hasExtensions  = $false
    $hasScreenshots = $false
    foreach ($GuestKey in $GuestList) {
        if ((Get-GuestTestScript -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir).Count -gt 0) {
            $hasExtensions = $true
        }
        if ((Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir).Count -gt 0) {
            $hasScreenshots = $true
        }
    }
    $StepNames = $BaseSteps
    if ($hasScreenshots) { $StepNames += @("Screenshots") }
    if ($hasExtensions)  { $StepNames += @("Invoke-PoolTest") }

    $VmStartTimeout = $Config.vmStartTimeoutSeconds ? [int]$Config.vmStartTimeoutSeconds : 120
    $VmBootDelay    = $Config.vmBootDelaySeconds    ? [int]$Config.vmBootDelaySeconds    : 15
    $CycleDelay     = $Config.cycleDelaySeconds     ? [int]$Config.cycleDelaySeconds     : $CycleDelaySeconds
    $GetImageRefreshHours = $Config.getImageRefreshHours ? [int]$Config.getImageRefreshHours : 24
    $StopOnFailure  = if ($Config.Contains('stopOnFailure')) { [bool]$Config.stopOnFailure } else { $false }

    # --- Initialize status for this cycle ---
    $CycleId = Initialize-StatusDocument `
        -StatusFilePath $StatusFile `
        -HostType       $HostType `
        -Hostname       (hostname) `
        -GitCommit      $GitCommit `
        -RepoUrl        $Config.repoUrl `
        -GuestList      $GuestList `
        -StepNames      $StepNames

    # --- Seed per-guest provenance so the UI shows the actual ISO filename
    # (e.g. "ubuntu-24.04.4-desktop-amd64.iso") instead of "guest.ubuntu.desktop".
    # Each Get-Image.ps1 writes a two-line sidecar (filename + source URL);
    # Get-BaseImageProvenance reads it. Missing sidecar or blank URL leaves
    # provenance empty and the UI falls back to guestKey. Per-cycle, so
    # deleting the ISO + re-running Get-Image reflects next cycle.
    foreach ($gk in $GuestList) {
        $imgPath = Get-ImagePath -HostType $HostType -GuestKey $gk
        if ($imgPath) {
            $prov = Get-BaseImageProvenance -BaseImagePath $imgPath
            Set-GuestProvenance -GuestKey $gk -Filename $prov.Filename -Url $prov.Url
        }
    }

    # --- Start log file (transcript captures console output) ---
    $LogFile = Start-LogFile -TestRoot $TestRoot -CycleId $CycleId -Hostname (hostname) -GitCommit $GitCommit
    Write-Output "Log file: $LogFile"

    Write-Output "Cycle ID: $CycleId"
    Write-Output "Commit:   $GitCommit"

    # --- Pre-flight: every guestOrder key needs a vde/host.<x>/<guest>/
    #     folder on this host. No hardcoded allow-list — this existence
    #     check IS the allow-list. Missing folders fail the guest and skip
    #     it for the rest of the cycle; stopOnFailure ends the cycle now.
    $FailedGuests = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($GuestKey in $GuestList) {
        if (Test-GuestFolder -VdeRoot $VdeRoot -HostType $HostType -GuestKey $GuestKey) { continue }
        $folder = Join-Path $VdeRoot "$HostType/$GuestKey"
        $err = "Guest folder not found: $folder"
        Write-Warning "  ERROR [$GuestKey / folder check]: $err"
        Write-Output "  (add a vde/$HostType/$GuestKey/ directory with Get-Image.ps1 + New-VM.ps1 to enable this guest on $HostType)"
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        # Attach the failure to the first step so the status UI shows it
        # on this guest's row (folder-check has no step of its own).
        if ($StepNames.Count -gt 0) {
            Set-StepStatus -GuestKey $GuestKey -StepName $StepNames[0] -Status "fail" -ErrorMessage $err
        }
        [void]$FailedGuests.Add($GuestKey)
        $OverallPassed = $false
        if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "folder-check"; $FailureMessage = $err }
        if ($StopOnFailure) { break }
    }


    if ($StopOnFailure -and -not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
        Stop-LogFile
        break
    }

    $lastGetImage = Get-LastGetImageTime -StatusFilePath $StatusFile
    $needGetImage = (-not $lastGetImage) -or ((Get-Date).ToUniversalTime() - [datetime]$lastGetImage).TotalHours -ge $GetImageRefreshHours
    if ($needGetImage) {
        Write-Output ""
        Write-Output "--- Get-Image (${GetImageRefreshHours}h refresh) ---"
        foreach ($GuestKey in $GuestList) {
            if ($FailedGuests.Contains($GuestKey)) { continue }
            Write-Output "Downloading image for $GuestKey..."
            $r = Invoke-GetImage -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -AlwaysRedownload $true
            if (-not $r.success) {
                Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                [void]$FailedGuests.Add($GuestKey)
                $OverallPassed = $false
                if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage }
                if ($StopOnFailure) { break }
                continue
            }
            Write-Output "  $GuestKey image: OK"
        }
        if ($OverallPassed) {
            Set-LastGetImageTime
            Write-Output "Get-Image complete. Timestamp updated."
        }
    } else {
        # Timer not expired, but verify each image exists. Re-download
        # any missing (manually deleted, first run after clean).
        $missingAny = $false
        foreach ($GuestKey in $GuestList) {
            if ($FailedGuests.Contains($GuestKey)) { continue }
            $imagePath = Get-ImagePath -HostType $HostType -GuestKey $GuestKey
            if (-not $imagePath -or -not (Test-Path $imagePath)) {
                $label = $imagePath ?? "$HostType/$GuestKey"
                Write-Output "Image file missing: $label — re-downloading..."
                $r = Invoke-GetImage -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -AlwaysRedownload $true
                if (-not $r.success) {
                    Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                    Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                    [void]$FailedGuests.Add($GuestKey)
                    $OverallPassed = $false
                    if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage }
                    $missingAny = $true
                    if ($StopOnFailure) { break }
                    continue
                }
                Write-Output "  $GuestKey image: OK (re-downloaded)"
            }
        }
        if (-not $missingAny) {
            Write-Output "Get-Image: skipped (last run: $lastGetImage, all images present)"
        }
    }

    Write-Output ""
    $testConfigMTime = (Test-Path $ConfigPath) ? (Get-Item $ConfigPath).LastWriteTime.ToString('u') : 'n/a'
    Write-Output "===== test-config.json: $testConfigMTime"
    if (Test-Path $ConfigPath) {
        try {
            $redacted = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable
            Remove-SecretsFromConfig $redacted
            $redacted | ConvertTo-Json -Depth 20 | Write-Output
        } catch {
            Write-Warning "Could not redact test-config.json for log: $_"
            Get-Content -Raw $ConfigPath | Write-Output
        }
    }

    # --- Abort cycle early if a pre-pipeline step failed under stopOnFailure ---
    if ($StopOnFailure -and -not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
        Stop-LogFile
        break
    }

    # --- Test each guest sequentially: cleanup → create → start → verify → screenshots → pool test → stop ---
    # One guest VM at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        if ($script:ShutdownState['Requested']) {
            Write-Output "Shutdown requested. Skipping remaining guests."
            $OverallPassed = $false; $FailedStep = "shutdown"
            break
        }
        # Skip guests that already failed pre-flight or Get-Image
        # (stopOnFailure=false path).
        if ($FailedGuests.Contains($GuestKey)) {
            Write-Output ""
            Write-Output "=== $GuestKey (skipped — earlier failure) ==="
            continue
        }
        $VMName = $VMNames[$GuestKey]
        $script:ActiveVMName = $VMName
        Write-Output ""
        Write-Output "=== $GuestKey (VM: $VMName) ==="

        # --- Cleanup previous VM ---
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
        $global:ProgressPreference = $savedProgress

        # --- New-VM ---
        Set-GuestVMName -GuestKey $GuestKey -VMName $VMName
        Set-GuestStatus -GuestKey $GuestKey -Status "running"

        Set-StepStatus -GuestKey $GuestKey -StepName "New-VM" -Status "running"
        # Forward the cache URL detected at runner startup so every guest
        # uses the same address. Without this, each guest's New-VM.ps1
        # probes independently and races with transient listeners (stale
        # DHCP leases, torn-down sibling VMs), baking a dead IP into the
        # cidata seed — seen on UTM where apt then fails with "No route
        # to host" at install. No cache detected → pass "" so guests
        # skip their probe: one detection event, one outcome.
        $newVmProxy = if ($cachingProxyUrl) { $cachingProxyUrl } else { "" }
        $r = Invoke-NewVM -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -VMName $VMName -CachingProxyUrl $newVmProxy
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "New-VM" -Status "pass"
            Write-Output "  $GuestKey New-VM: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / New-VM]: $($r.errorMessage)"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "New-VM"; $FailureMessage = $r.errorMessage
            if ($StopOnFailure) { break }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            continue
        }

        # --- Start-VM ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "running"
        $r = Invoke-StartVM -HostType $HostType -VMName $VMName
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "pass"
            Write-Output "  $GuestKey Start-VM: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / Start-VM]: $($r.errorMessage)"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Start-VM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Start-VM"; $FailureMessage = $r.errorMessage
            if ($StopOnFailure) { break }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            continue
        }

        # --- Install-OS (Test-Start scripts drive OS installation) ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Install-OS" -Status "running"
        $showExtOutput = -not $NoExtensionOutput
        $r = Invoke-StartTest -HostType $HostType -GuestKey $GuestKey -VMName $VMName -ExtensionsDir $ExtensionsDir -ShowOutput $showExtOutput
        if ($r.skipped) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Install-OS" -Status "skipped" -Skipped $true
        } elseif ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Install-OS" -Status "pass"
            Write-Output "  $GuestKey Install-OS: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / Install-OS]: $($r.errorMessage)"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Install-OS" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Install-OS"; $FailureMessage = $r.errorMessage
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                break
            }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
            Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
            $global:ProgressPreference = $savedProgress
            continue
        }

        # --- Verify-VM (poll until running, wait boot delay) ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Verify-VM" -Status "running"
        $ok = Confirm-VMStarted -HostType $HostType -VMName $VMName `
            -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
        if (-not $ok) {
            $err = "VM '$VMName' did not reach running state after start."
            Write-Warning "  ERROR [$GuestKey / Verify-VM]: $err"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Verify-VM" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Verify-VM"; $FailureMessage = $err
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                break
            }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
            Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
            $global:ProgressPreference = $savedProgress
            continue
        }
        Write-Output "  $GuestKey Verify-VM: PASS"
        Set-StepStatus -GuestKey $GuestKey -StepName "Verify-VM" -Status "pass"

        # --- Screenshots (compare against trained references) ---
        if ($hasScreenshots) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "running"
            $r = Invoke-ScreenshotTest -HostType $HostType -GuestKey $GuestKey `
                -VMName $VMName -ScreenshotsDir $ScreenshotsDir
            if ($r.skipped) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "skipped" -Skipped $true
            } elseif ($r.success) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "pass"
            } else {
                Write-Warning "  ERROR [$GuestKey / Screenshots]: $($r.errorMessage)"
                Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Screenshots" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Screenshots"; $FailureMessage = $r.errorMessage
                if ($StopOnFailure) {
                    Write-Output "  VM '$VMName' left running for investigation."
                    break
                }
                Copy-FailureArtifactsToStatusLog -VMName $VMName
                Write-Output "  Cleaning up VM '$VMName' after failure..."
                $savedProgress = $global:ProgressPreference
                $global:ProgressPreference = 'SilentlyContinue'
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
                $global:ProgressPreference = $savedProgress
                continue
            }
        }

        # --- Invoke-PoolTest (extension scripts) ---
        if ($hasExtensions) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "running"
            $r = Invoke-PoolTest -HostType $HostType -GuestKey $GuestKey -VMName $VMName -ExtensionsDir $ExtensionsDir -ShowOutput $showExtOutput
            if ($r.skipped) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "skipped" -Skipped $true
            } elseif ($r.success) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "pass"
                Write-Output "  $GuestKey Invoke-PoolTest: PASS"
            } else {
                Write-Warning "  ERROR [$GuestKey / Invoke-PoolTest]: $($r.errorMessage)"
                Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Invoke-PoolTest"; $FailureMessage = $r.errorMessage
                if ($StopOnFailure) {
                    Write-Output "  VM '$VMName' left running for investigation."
                    break
                }
                Copy-FailureArtifactsToStatusLog -VMName $VMName
                Write-Output "  Cleaning up VM '$VMName' after failure..."
                $savedProgress = $global:ProgressPreference
                $global:ProgressPreference = 'SilentlyContinue'
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
                $global:ProgressPreference = $savedProgress
                continue
            }
        }

        # --- Stop and remove this guest VM before starting the next ---
        Set-GuestStatus -GuestKey $GuestKey -Status "pass"
        Write-Output "  ${GuestKey}: PASS"
        Write-Output "  Stopping VM '$VMName'..."
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
        Write-Output "  Removing VM '$VMName'..."
        Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
        $global:ProgressPreference = $savedProgress
        Write-Output "  Cleanup complete for $GuestKey."
        $script:ActiveVMName = $null
    }

    # === Finalise cycle ===
    $FinalStatus = $OverallPassed ? "pass" : "fail"
    Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
    Stop-LogFile
    $script:CycleFinalized = $true

    Write-Output ""
    Write-Output "=== Cycle $CycleCount complete: $FinalStatus ==="

    if ($OverallPassed) {
        $ConsecutiveCrashes  = 0
        $ConsecutiveFailures = 0
        $ConsecutiveSuccesses++
        if (-not $AlertArmed -and $ConsecutiveSuccesses -ge $SuccessesBeforeRearm) {
            $AlertArmed = $true
            Write-Output "  Notification alert rearmed after $ConsecutiveSuccesses consecutive successes."
        }
    }

    if (-not $OverallPassed) {
        $ConsecutiveSuccesses = 0
        $ConsecutiveFailures++
        if ($StopOnFailure) {
            break
        }
        # Send notification but continue to next cycle
        if ($FailedGuest) {
            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  FAILURE in cycle $CycleCount (continuing)"
            Write-Output "  Guest:   $FailedGuest"
            Write-Output "  Step:    $FailedStep"
            Write-Output "  Error:   $FailureMessage"
            Write-Output "  Alert:   $ConsecutiveFailures/$FailuresBeforeAlert failures $(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})"
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

            if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
                $body = Format-FailureMessage `
                    -HostType     $HostType `
                    -Hostname     (hostname) `
                    -GuestKey     $FailedGuest `
                    -StepName     $FailedStep `
                    -ErrorMessage $FailureMessage `
                    -CycleId      $CycleId `
                    -GitCommit    $GitCommit
                Send-Notification -Config $Config `
                    -Subject "Yuruna VDE Test: FAIL on $HostType / $FailedGuest / $FailedStep" `
                    -Body    $body
                $AlertArmed           = $false
                $ConsecutiveSuccesses = 0
                Write-Output "  Notification sent. Alert suppressed until $SuccessesBeforeRearm consecutive successes or runner restart."
            }
        }
    }

    if ($Warnings.Count -gt 0) {
        Write-Output ""
        Write-Output "--- Warnings ---"
        foreach ($w in $Warnings) {
            Write-Warning "  $w"
        }
    }

  } catch {
    # --- Unhandled exception in cycle — emergency cleanup ---
    $ConsecutiveCrashes++
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  UNHANDLED ERROR in cycle $CycleCount"
    Write-Output "  $_"
    # Print the error origin. Otherwise the operator sees only the message
    # (e.g. "Cannot convert value ' Install ' to 'System.Int32'") and has
    # to grep ten modules to guess the source. PositionMessage gives
    # file:line of the throwing statement; ScriptStackTrace gives the
    # call chain — together they pin the source on a single re-run.
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Output "  Origin:"
        foreach ($line in ($_.InvocationInfo.PositionMessage -split "`n")) {
            Write-Output "    $line"
        }
    }
    if ($_.ScriptStackTrace) {
        Write-Output "  Stack:"
        foreach ($line in ($_.ScriptStackTrace -split "`n")) {
            Write-Output "    $line"
        }
    }
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    # Emergency-stop/remove any VM in progress
    if ($script:ActiveVMName) {
        try {
            Write-Output "  Emergency cleanup: stopping VM '$($script:ActiveVMName)'..."
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-TestVM -HostType $HostType -VMName $script:ActiveVMName -ErrorAction SilentlyContinue | Out-Null
            Remove-TestVM -HostType $HostType -VMName $script:ActiveVMName -ErrorAction SilentlyContinue | Out-Null
            $global:ProgressPreference = $savedProgress
        } catch { Write-Warning "  Emergency VM cleanup failed: $_" }
        $script:ActiveVMName = $null
    }

    # Finalize cycle if not already done
    if (-not $script:CycleFinalized) {
        try {
            Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns) -ErrorAction SilentlyContinue
            Stop-LogFile -ErrorAction SilentlyContinue
        } catch { Write-Warning "  Emergency cycle finalization failed: $_" }
        $script:CycleFinalized = $true
    }

    if ($ConsecutiveCrashes -ge $MaxConsecutiveCrashes) {
        Write-Output "  $ConsecutiveCrashes consecutive unhandled errors — aborting."
        $OverallPassed = $false
        break
    }
    Write-Output "  Will retry next cycle ($ConsecutiveCrashes/$MaxConsecutiveCrashes consecutive errors)."
  }

    if ($script:ShutdownState['Requested']) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    # Clean up all test VMs and files before the inter-cycle wait
    & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix

    # Cycle-pause back-channel: status server's /control/cycle-pause
    # endpoint creates $env:YURUNA_TRACK_DIR/control.cycle-pause. Gate
    # here — AFTER cleanup, BEFORE the inter-cycle wait — so the UI's
    # "Cycle pause" stops the runner at the cycle boundary with VMs torn
    # down. /control/cycle-resume removes the file and the loop proceeds
    # to the normal wait. ShutdownState is checked alongside so Ctrl-C
    # still breaks out of the wait.
    $cyclePauseFlagFile = Join-Path $env:YURUNA_TRACK_DIR 'control.cycle-pause'
    if (Test-Path $cyclePauseFlagFile) {
        Write-Output "Cycle pause set via status UI. Waiting for resume..."
        while ((Test-Path $cyclePauseFlagFile) -and (-not $script:ShutdownState['Requested'])) {
            Start-Sleep -Seconds 1
        }
        if ($script:ShutdownState['Requested']) {
            Write-Output "Shutdown requested during cycle pause. Exiting cycle loop."
            break
        }
        Write-Output "Cycle pause released. Resuming."
    }

    $delay = if ($CycleDelay) { $CycleDelay } else { $CycleDelaySeconds }
    for ($remaining = $delay; $remaining -gt 0; $remaining--) {
        $pct = [math]::Round((($delay - $remaining) / $delay) * 100)
        Write-Progress -Activity "Next cycle" -Status "in $remaining seconds..." -PercentComplete $pct
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity "Next cycle" -Completed

    # Clean up all test VMs and files after the inter-cycle wait
    & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix
}

Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue

# Release runner.pid on graceful exit — only if it still points to us.
# A competing runner may have taken over and rewritten the file with its
# own PID; don't clobber theirs. Crash / kill -9 / power loss leaves a
# stale PID; next startup's single-instance guard handles it.
try {
    if (Test-Path $RunnerPidFile) {
        $filePid = 0
        # Malformed pidfile → leave it alone (don't remove something we
        # can't identify as ours). $filePid stays 0 so the -eq $PID check
        # below is false.
        try { $filePid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
        if ($filePid -eq $PID) {
            Remove-Item $RunnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    # Shutdown cleanup is best-effort: any failure (pidfile race with a
    # competing runner, fs permission blip) leaves a possibly-stale file.
    # Fine — the single-instance guard handles it on next launch.
    Write-Verbose "Shutdown pidfile cleanup swallowed error: $($_.Exception.Message)"
}

# === Failure notification (only reached when stopOnFailure breaks the loop) ===
if (-not $OverallPassed -and $FailedGuest) {
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  FAILURE SUMMARY"
    Write-Output "  Host:    $HostType"
    Write-Output "  Guest:   $FailedGuest"
    Write-Output "  Step:    $FailedStep"
    Write-Output "  Error:    $FailureMessage"
    Write-Output "  Cycle ID: $CycleId"
    Write-Output "  Commit:   $GitCommit"
    Write-Output "  Log:     $LogFile"
    Write-Output "  Alert:   $ConsecutiveFailures/$FailuresBeforeAlert failures $(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})"
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output ""
    Write-Output "To reproduce with full diagnostics:"
    Write-Output "  pwsh test/Invoke-TestRunner.ps1 -NoGitPull -debug_mode `$true -verbose_mode `$true"

    if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
        $body = Format-FailureMessage `
            -HostType     $HostType `
            -Hostname     (hostname) `
            -GuestKey     $FailedGuest `
            -StepName     $FailedStep `
            -ErrorMessage $FailureMessage `
            -CycleId      $CycleId `
            -GitCommit    $GitCommit
        Send-Notification -Config $Config `
            -Subject "Yuruna VDE Test: FAIL on $HostType / $FailedGuest / $FailedStep" `
            -Body    $body
    } else {
        Write-Output "  Notification suppressed ($ConsecutiveFailures/$FailuresBeforeAlert failures, armed=$AlertArmed)."
    }
}

exit ($OverallPassed ? 0 : 1)
