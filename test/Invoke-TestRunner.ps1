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

# The global variable is the cross-module communication channel with yuruna-log.
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
$TestRoot       = $PSScriptRoot
$RepoRoot       = Split-Path -Parent $TestRoot
$VdeRoot        = Join-Path $RepoRoot "vde"
$StatusDir      = Join-Path $TestRoot "status"
$StatusFile     = Join-Path $StatusDir "status.json"
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ModulesDir     = Join-Path $TestRoot "modules"
$ExtensionsDir  = Join-Path $TestRoot "extensions"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"
$VerifyDir      = Join-Path $TestRoot "verify"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }
$TemplatePath = Join-Path $TestRoot "test-config.json.template"

# === Single-instance guard ===
# If another Invoke-TestRunner.ps1 is already running, stop it and wipe
# any stranded test VMs before we start. Scenario: the operator launched
# the runner in a second terminal without realising the first was still
# going; both instances then race on the same VM names and shared status
# files, and half the VMs end up stuck in Starting/Stopping state.
#
# The YURUNA_RUNNER_RELAUNCH env var marks the source-change relaunch
# branch below — that branch intentionally spawns a child Invoke-TestRunner.ps1
# and we don't want the child to treat its own parent as a competitor.
$RunnerPidFile = Join-Path $StatusDir "runner.pid"
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1' -and (Test-Path $RunnerPidFile)) {
    $existingPid = 0
    # Unreadable / malformed / missing pidfile is treated as "no prior
    # runner" — the single-instance check below still runs on $existingPid
    # = 0 (Get-Process of 0 returns null) so the branch is a safe no-op.
    try { $existingPid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $existingPid = 0 }
    if ($existingPid -gt 0 -and $existingPid -ne $PID -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        # Verify the PID belongs to an Invoke-TestRunner.ps1 process — don't
        # kill an arbitrary process that happens to have recycled this PID.
        # Windows uses CIM; macOS/Linux use /bin/ps (path-qualified so PSSA
        # doesn't confuse this with the `ps` alias for Get-Process — we
        # need the external binary for `-o args=` which Get-Process can't
        # produce portably on Unix).
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
            # Wait briefly for the old process to die before cleanup so its
            # Hyper-V/UTM VM ops can't race with ours.
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 500
            }
            try {
                $cleanup = Join-Path $TestRoot "Remove-TestVMFiles.ps1"
                if (Test-Path $cleanup) {
                    # 'test-' is the stock prefix and matches the template.
                    # test-config.json hasn't been merged yet at this point,
                    # so we can't read the user's override. Acceptable trade:
                    # worst case the user picked a custom prefix and this
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
# Record our PID regardless of the relaunch branch. On relaunch the child
# overwrites the parent's entry; that's deliberate — the child is the one
# doing real work, so it should own the lock.
$PID | Set-Content -Path $RunnerPidFile -Encoding ascii

# === Publish debug/verbose preferences as env vars so child processes inherit them ===
$env:YURUNA_DEBUG   = $debug_mode   ? '1' : '0'
$env:YURUNA_VERBOSE = $verbose_mode ? '1' : '0'

# === Import all modules (suppress engine verbose noise during imports) ===
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "yuruna-log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

foreach ($mod in @("Test.Host", "Test.Status", "Test.Notify", "Test.Get-Image", "Test.New-VM", "Test.Start-VM", "Test.Install-OS", "Test.Screenshot", "Test.Invoke-PoolTest", "Test.Log", "Test.CachingProxy", "Test.PortMap")) {
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
# At the start of each cycle the live config is overlaid on top of the
# template so that new keys introduced in the template are added locally
# without losing user-set values. The merged object is rewritten to disk
# only when it differs from the on-disk copy outside the 'secrets' subtree
# (user credentials always diverge from the template blanks — including
# them in the diff would churn the file every cycle).

# Recursively overlay $Current values onto $Template. Template shape wins
# (which keys exist); current values win for overlapping scalar and array
# entries. Keys that only exist in $Current are dropped — the template is
# the schema source of truth. Output keys are emitted in alphabetical order
# at every nesting level so regenerated test-config.json is stable and
# independent of the template file's own key ordering.
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

# Return a shallow clone of $Config without its top-level 'secrets' key,
# used only for diff comparison.
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
    # notification.resend.{apiKey,from} used to live under notification; move
    # any values we find there into secrets.resend so the merge below (which
    # drops template-orphan keys) doesn't lose them.
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

    # Validate keystrokeMechanism. Canonical values are "GUI" and "SSH";
    # recognition is case-insensitive (so "gui"/"Ssh"/etc. are accepted) and
    # the value is normalized to uppercase when written back. Any unrecognized
    # value (including the legacy "hypervisor" from older checkouts) is
    # discarded and replaced with the template default. No migration.
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

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1") -Force
$global:VerbosePreference = $savedVerbose
$null = Initialize-YurunaLogDir
Write-Output "Log directory: $env:YURUNA_LOG_DIR"

# Proxy-cache detection moved to Test.CachingProxy.psm1 so Start-StatusServer
# can share the same probe — both writers (console banner here, status-page
# banner via status/log/caching-proxy.txt) stay in lockstep with whatever URL
# gets injected into autoinstall user-data by guest.ubuntu.desktop/New-VM.ps1.
$cachingProxyUrl = Test-CachingProxyAvailable -HostType $HostType

# When a local cache is detected, expose the VM's ports on the host so
# LAN clients and operators on other machines can reach the proxy, the
# ssl-bump listener, Apache's CA cert, and the Grafana dashboard without
# reaching into the VM's NAT subnet directly. Add-CachingProxyPortMap
# dispatches per-platform via Test.PortMap.psm1 — netsh portproxy +
# firewall rule on Hyper-V, detached TcpListener forwarders on macOS/UTM.
# When no cache is detected, undo any mapping a prior cycle left in place.
#
# Port list is @(80, 3128, 3129, 3000) on both platforms and MUST match
# the Start-CachingProxy.ps1 call site — Add-CachingProxyPortMap runs
# Clear-AllCachingProxyPortMapping first, so a narrower list at either
# caller would tear down ports the other just set up. Local guests
# continue to reach the VM directly on their NAT subnet regardless of
# what's mapped on the host.
#
# External-cache branch: when $Env:YURUNA_CACHING_PROXY_IP is set,
# Test-CachingProxyAvailable returns the remote URL and the remote host is
# assumed to serve all four ports itself. Guests reach the remote IP via
# the host's outbound NAT, so no local portproxy or forwarder is needed —
# we skip Add-CachingProxyPortMap entirely and link the dashboard directly
# at the remote IP. Remove any leftover mappings from a prior local-cache
# cycle so the old VM IP doesn't keep answering stale proxy requests.
#
# The detection line renders the word "detected" as an ANSI OSC 8
# hyperlink to the Grafana dashboard so operators in a modern terminal
# (Windows Terminal, VS Code integrated) can ctrl-click straight to the
# caching proxy view. Terminals without OSC 8 support drop the escapes
# silently and just show "detected" as plain text — no regression.
if ($cachingProxyUrl) {
    $vmIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
    $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_IP
    $mapOk = $false
    $bestIp = $null
    if ($isExternal) {
        # Remote cache serves its own ports; clear any local mapping a
        # prior cycle left, then point the dashboard at the remote.
        [void](Remove-CachingProxyPortMap)
        $mapOk = $true
        $bestIp = $vmIp
    } elseif ($vmIp) {
        $CachingProxyExposedPorts = @(80, 3128, 3129, 3000)
        $mapResult = Add-CachingProxyPortMap -VMIp $vmIp -Port $CachingProxyExposedPorts
        $mapOk = [bool]$mapResult
        $bestIp = Get-BestHostIp
        if (-not $bestIp) { $bestIp = $vmIp }  # fallback when no routable iface is found
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
        # Include a UTC error timestamp so multiple failures within the same run don't overwrite each other
        $errorTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')

        $srcScreen = Join-Path $env:YURUNA_LOG_DIR "failure_screenshot_${VMName}.png"
        if (Test-Path $srcScreen) {
            $destName = "$logId.$errorTimestamp.failure-screenshot.png"
            $dest = Join-Path $statusLogDir $destName
            Copy-Item -Path $srcScreen -Destination $dest -Force
            Write-Output "  Failure screenshot saved: ./status/log/$destName"
            # Write clickable HTML link directly to log file (bypasses proxy encoding)
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
# The CancelKeyPress event handler runs in a separate SessionState (because
# Register-ObjectEvent -Action creates its own scope). A plain $script:var
# would not propagate back to the main runner. Use a thread-safe dictionary
# as shared state so both the event action and the main loop see the same
# flag without any scope or runspace issues.
$script:ShutdownState = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()
$script:ShutdownState['Requested'] = $false
$script:ActiveVMName      = $null
$script:CycleFinalized    = $true    # tracks whether Complete-Run/Stop-LogFile have been called

try {
    # Use Register-ObjectEvent instead of [Console]::add_CancelKeyPress() so
    # the handler runs on the PowerShell pipeline thread where a runspace
    # exists. A raw .NET event delegate fires on a CLR thread-pool thread
    # that has no runspace, which causes a fatal PSInvalidOperationException
    # ("There is no Runspace available to run scripts in this thread") and
    # kills the entire process — preventing graceful cleanup.
    $shutdownRef = $script:ShutdownState
    # Clean up any subscriber/job left behind by a prior run that exited
    # without reaching the bottom-of-script Unregister-Event (Ctrl+C, error,
    # IDE-terminated session). Without this, re-running in the same shell
    # fails with "A subscriber with the source identifier ... already exists".
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

# === Source-change detection: capture mtimes so the next cycle can relaunch ===
# if Invoke-TestRunner.ps1 or any module under test/modules is edited mid-run.
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
# failuresBeforeAlert : consecutive cycle failures required before sending an alert.
# successesBeforeRearm: consecutive successes (or a fresh Invoke-TestRunner start)
#                       required before the alert can fire again.
# State machine: Armed → (N consecutive failures) → Fired → (M consecutive successes) → Armed
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

    # Relaunch into a fresh process if the script or any module changed on disk
    # since this process started. The currently running process has parsed
    # sources cached in memory; only a new process will pick up edits.
    $currentFingerprint = Get-SourceFingerprint -ScriptPath $PSCommandPath -ModulesDir $ModulesDir
    if ($currentFingerprint -ne $script:SourceFingerprint) {
        Write-Output "Source changed on disk — relaunching Invoke-TestRunner.ps1 for next cycle..."
        $pwshExe = (Get-Process -Id $PID).Path
        # Signal the child to skip the single-instance guard — it would
        # otherwise see this parent's runner.pid and kill the only process
        # we actually want running.
        $env:YURUNA_RUNNER_RELAUNCH = '1'
        try {
            & $pwshExe -NoLogo -File $PSCommandPath @PSBoundParameters
        } finally {
            Remove-Item Env:YURUNA_RUNNER_RELAUNCH -ErrorAction SilentlyContinue
        }
        exit $LASTEXITCODE
    }

    # Re-check all host conditions before each cycle — settings can revert
    # (e.g. after a system update or user change) between long-running cycles.
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

    # Build VM name map — algorithmic derivation (see Get-TestVMName) so any
    # guest key from guestOrder produces a stable VM name without requiring
    # a hardcoded lookup per guest.
    $VMNames = @{}
    foreach ($GuestKey in $GuestList) {
        $VMNames[$GuestKey] = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
    }

    # Determine step list based on available extensions and screenshot schedules
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

    # --- Start log file (transcript captures all console output) ---
    $LogFile = Start-LogFile -TestRoot $TestRoot -CycleId $CycleId -Hostname (hostname) -GitCommit $GitCommit
    Write-Output "Log file: $LogFile"

    Write-Output "Cycle ID: $CycleId"
    Write-Output "Commit:   $GitCommit"

    # --- Pre-flight: every guest-key in guestOrder must have a vde/host.<x>/<guest>/
    #     folder on this host. There is no hardcoded known-guests allow-list; this
    #     existence check IS the allow-list. Guests that don't exist on the current
    #     host are marked fail and skipped for the rest of the cycle; stopOnFailure
    #     ends the cycle immediately.
    $FailedGuests = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($GuestKey in $GuestList) {
        if (Test-GuestFolder -VdeRoot $VdeRoot -HostType $HostType -GuestKey $GuestKey) { continue }
        $folder = Join-Path $VdeRoot "$HostType/$GuestKey"
        $err = "Guest folder not found: $folder"
        Write-Warning "  ERROR [$GuestKey / folder check]: $err"
        Write-Output "  (add a vde/$HostType/$GuestKey/ directory with Get-Image.ps1 + New-VM.ps1 to enable this guest on $HostType)"
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        # Attach the failure to the first step so the status UI shows it against
        # this guest's row (the Discover/folder-check phase doesn't have its own step).
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
        # Timer not expired, but verify each image file actually exists.
        # Re-download any that are missing (e.g. manually deleted or first run after a clean).
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

    # --- Test each guest sequentially (cleanup → create → start → verify → screenshots → pool test → stop) ---
    # Only one guest VM exists at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        if ($script:ShutdownState['Requested']) {
            Write-Output "Shutdown requested. Skipping remaining guests."
            $OverallPassed = $false; $FailedStep = "shutdown"
            break
        }
        # Skip guests that already failed the pre-flight folder check or
        # Get-Image step when stopOnFailure is false.
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
        # Forward the cache URL detected once at runner startup so every
        # guest in this run uses the same address. Omitting this lets
        # each guest's New-VM.ps1 probe independently, which races with
        # transient listeners (stale DHCP leases, torn-down sibling VMs)
        # and can bake a dead IP into the cidata seed — observed on UTM
        # where apt then fails with "No route to host" at install time.
        # When no cache was detected, pass "" so guests skip their own
        # probe and go direct: one detection event, one outcome.
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

        # --- Install-OS (run Test-Start scripts to drive OS installation) ---
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

        # --- Verify-VM (poll until running, wait boot delay, then verify screenshot) ---
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
        # Check verification screenshot if one exists for this host+guest
        $verifyRef = Get-VerifyScreenshot -HostType $HostType -GuestKey $GuestKey -VerifyDir $VerifyDir
        if ($verifyRef) {
            $verifyFileName = "$HostType.$GuestKey.png"
            $verifyCapture = Join-Path $VerifyDir "actual/$verifyFileName"
            $actualDir = Join-Path $VerifyDir "actual"
            if (-not (Test-Path $actualDir)) { New-Item -ItemType Directory -Force -Path $actualDir | Out-Null }
            $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $verifyCapture
            if ($captured) {
                $threshold = $Config.verifyScreenshotThreshold ? [double]$Config.verifyScreenshotThreshold : 0.85
                $cmp = Compare-Screenshot -ReferencePath $verifyRef -ActualPath $verifyCapture -Threshold $threshold
                if (-not $cmp.match) {
                    $err = "Verify screenshot mismatch: similarity=$($cmp.similarity) threshold=$threshold"
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
                Write-Output "  $GuestKey Verify-VM: PASS (screenshot similarity=$($cmp.similarity))"
            } else {
                Write-Output "  $GuestKey Verify-VM: PASS (screenshot capture skipped)"
            }
        } else {
            Write-Output "  $GuestKey Verify-VM: PASS"
        }
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
    # Print the origin of the error. Without these the operator sees only
    # the message (e.g. "Cannot convert value ' Install ' to type
    # 'System.Int32'") and has to grep ten modules to guess where it came
    # from. PositionMessage gives the file:line of the throwing statement,
    # and ScriptStackTrace gives the call chain -- together they pin the
    # source down on a single re-run.
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

    # Stop/remove the active VM if one was in progress
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

    # Finalize the cycle if not already done
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

    # Cycle-pause back-channel: the status server's /control/cycle-pause
    # endpoint creates test/status/control.cycle-pause. We gate here, AFTER
    # cleanup but BEFORE the inter-cycle wait, so pressing "Cycle pause" in
    # the UI cleanly stops the runner at the cycle boundary with the previous
    # cycle's VMs already torn down. Removing the file (via
    # /control/cycle-resume) lets the loop proceed into the normal
    # inter-cycle delay and on to the next cycle. ShutdownState is checked
    # alongside the file so Ctrl-C can still break out of the wait.
    $cyclePauseFlagFile = Join-Path $StatusDir 'control.cycle-pause'
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

# Release runner.pid on graceful exit. Only delete if it still points to
# us — a competing runner may have taken over since (and rewritten the
# file with its own PID) and we shouldn't clobber theirs. A crash / kill
# -9 / power loss leaves a stale PID behind; that's fine, the next
# startup's single-instance guard detects it and handles it.
try {
    if (Test-Path $RunnerPidFile) {
        $filePid = 0
        # Malformed pidfile → leave it alone (don't remove something we
        # can't identify as ours). $filePid stays 0 so the -eq $PID
        # comparison below is false.
        try { $filePid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
        if ($filePid -eq $PID) {
            Remove-Item $RunnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    # Shutdown-path cleanup is strictly best-effort: any failure here
    # (pidfile race with a competing runner, fs permission blip) leaves
    # a possibly-stale file behind. That's fine — the single-instance
    # guard at script start handles stale pidfiles on the next launch.
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
