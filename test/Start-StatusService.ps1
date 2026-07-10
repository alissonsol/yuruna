<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456740
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
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
    Starts the status HTTP server as an independent background process.

.DESCRIPTION
    Launches a detached pwsh process that serves the test/status/ directory
    over HTTP. The server keeps running even if the caller exits.
    A PID file ($env:YURUNA_RUNTIME_DIR/server.pid) is written so
    Stop-StatusService.ps1 can shut it down later.

.PARAMETER Port
    TCP port to listen on. Defaults to the value in test.config.yml,
    or 8080 if not configured.

.PARAMETER Restart
    Stop any existing server before starting a new one. Use this after
    a git pull or config change to ensure the server picks up new files.
#>

param(
    [int]$Port = 0,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"

# Seconds to wait for the detached status server to start answering on $Port
# before emitting the "not responding" warning. The loop polls once per
# second, so this is also the maximum number of poll attempts.
$script:StatusServiceReadyTimeoutSeconds = 60

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$TestRoot   = $paths.TestRoot
$RepoRoot   = $paths.RepoRoot
$StatusDir  = $paths.StatusDir
$ModulesDir = $paths.ModulesDir

# $env:YURUNA_RUNTIME_DIR (runtime state) + $env:YURUNA_LOG_DIR (transcripts/
# debug artifacts). Default to status/ subdirs so the HTTP server serves
# them at /runtime/* and /log/*. Other status/ subdirs (perf/, extension/,
# captures/, ssh/) are served straight from $StatusDir as relative paths.
# StatusService kind imports Test.YurunaDir, Test.VMUtility, Test.CachingProxy,
# Test.PortOwner, and Test.HostContract -- one call replaces five inline imports
# spread across the bootstrap section of this script.
Initialize-YurunaEntryPointModuleSet -For StatusService -ModulesDir $ModulesDir
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
$RuntimeDir = $env:YURUNA_RUNTIME_DIR
$LogDir     = $env:YURUNA_LOG_DIR

$PidFile = Join-Path $RuntimeDir "server.pid"

if ($Port -le 0) {
    $configPath = Join-Path $TestRoot "test.config.yml"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered
            if ($config.statusService.port) { $Port = [int]$config.statusService.port }
        } catch { Write-Warning "Could not read port from config: $_" }
    }
    if ($Port -le 0) { $Port = 8080 }
}

if ($Restart -and (Test-Path $PidFile)) {
    $oldPid = (Get-Content $PidFile).Trim()
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match 'pwsh|PowerShell') {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Write-Output "Stopped existing status server (PID $oldPid)."
            Start-Sleep -Seconds 1
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# --- REGION: Check for an existing server
# The detached server bakes the ~1.5 KLOC here-string (and the modules
# it imports at startup) into its in-memory state. Files under test/status/
# are served from disk per request, so frontend edits do NOT need a
# restart; only a change in the framework code does. We persist the
# framework HEAD SHA to server.sha at launch and compare it here, so the
# zero-change cycle of the inner runner (the common case) is a no-op
# instead of a 1 s teardown + multi-second relaunch. Cycle-start downtime
# drops from "every cycle" to "only when `git pull` actually pulled
# something that affects the server".
$ShaFile = Join-Path $RuntimeDir 'server.sha'
if (Test-Path $PidFile) {
    $oldPid = (Get-Content $PidFile).Trim()
    $serverAlive = $false
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        # Verify PID is a pwsh process (not a recycled PID)
        if ($proc -and $proc.ProcessName -match 'pwsh|PowerShell') {
            try {
                $null = Invoke-WebRequest -Uri "http://localhost:$Port/status.json" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
                $serverAlive = $true
            } catch {
                Write-Output "PID $oldPid exists but port $Port is not responding. Replacing server."
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
        }
    }
    if ($serverAlive) {
        $currentSha = $null
        try {
            $currentSha = (& git -C $RepoRoot rev-parse HEAD 2>$null | Out-String).Trim()
        } catch { Write-Verbose "server.sha probe: git rev-parse failed: $($_.Exception.Message)" }
        $persistedSha = $null
        if (Test-Path -LiteralPath $ShaFile) {
            try { $persistedSha = (Get-Content -LiteralPath $ShaFile -Raw).Trim() } catch { Write-Verbose "server.sha read failed: $($_.Exception.Message)" }
        }
        if ($currentSha -and $persistedSha -and ($currentSha -eq $persistedSha)) {
            Write-Output "Status server is already running on the current framework SHA (PID $oldPid, port $Port, sha $($currentSha.Substring(0,[Math]::Min(12,$currentSha.Length))))."
            Write-Output "Stop with: .\Stop-StatusService.ps1"
            exit 0
        }
        # SHA differs (or either side is unknown). Tear down + fall
        # through to the launch path so the new framework code is
        # picked up. Conservative on unknown: an unwritten / unreadable
        # server.sha (e.g. upgrade from an older Start-StatusService
        # that didn't persist it) forces a restart rather than risking
        # a stale-code server.
        $reason = if (-not $currentSha) { 'current HEAD unknown' }
                  elseif (-not $persistedSha) { 'no persisted SHA' }
                  else { "framework SHA changed ($persistedSha -> $currentSha)" }
        Write-Output "Restarting status server (PID $oldPid): $reason."
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# Resolve port conflicts from untracked orphan detached servers.
# Why it's needed and the Test.PortOwner.psm1 dispatch contract:
# https://yuruna.link/test/harness
$portResolution = Resolve-PortOrphan -Port $Port -PidFile $PidFile -Confirm:$false
if ($portResolution.Status -eq 'Conflict') {
    foreach ($line in ($portResolution.Message -split "`n")) { Write-Warning $line.TrimEnd() }
    # Refuse, and make the refusal PROPAGATE. A bare `exit 1` here would only
    # set $LASTEXITCODE for the call-operator invocation the shared gate runs
    # (`& $StartScript`), so the parent cycle would carry on without a status
    # server — the blind-cycle trap this guards against. Throw a tagged
    # exception instead: Start-YurunaStatusServiceIfEnabled recognizes the tag
    # and aborts the entry point cleanly; a standalone run exits non-zero on the
    # uncaught throw. The detection is OS-agnostic (HttpListener bind probe), so
    # this fires identically on macOS/UTM, Ubuntu/KVM, and Windows/Hyper-V.
    $conflict = [System.InvalidOperationException]::new("Status-service port $Port is held by another process; refusing to start.")
    $conflict.Data['YurunaPortConflict'] = $true
    $conflict.Data['YurunaPort'] = $Port
    throw $conflict
}

# --- REGION: Ensure repoUrl is set in status.json
$StatusFile = Join-Path $RuntimeDir "status.json"
if (Test-Path $StatusFile) {
    try {
        $statusDoc = Get-Content -Raw $StatusFile | ConvertFrom-Json
        $configPath = Join-Path $TestRoot "test.config.yml"
        $config = $null
        if (Test-Path $configPath) {
            try { $config = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered } catch { Write-Verbose "Could not parse test.config.yml: $_" }
        }
        $repoUrl = $null
        if ($config -and $config.repositories -and $config.repositories.frameworkUrl) { $repoUrl = $config.repositories.frameworkUrl }
        if (-not $repoUrl -and $statusDoc.repoUrl) { $repoUrl = $statusDoc.repoUrl }
        if (-not $repoUrl) {
            $remote = & git -C $RepoRoot remote get-url origin 2>&1
            if ($LASTEXITCODE -eq 0 -and $remote -and $remote -match '^(https?://|git@)') {
                $repoUrl = ($remote -replace '\.git$', '')
            } elseif ($LASTEXITCODE -eq 0 -and $remote) {
                Write-Warning "Git remote URL has unexpected format, skipping: $remote"
            } else {
                Write-Warning "Could not derive repoUrl from git remote: $remote"
            }
        }
        if ($repoUrl -and (-not $statusDoc.repoUrl -or $statusDoc.repoUrl -ne $repoUrl)) {
            if ($statusDoc.PSObject.Properties['repoUrl']) {
                $statusDoc.repoUrl = $repoUrl
            } else {
                $statusDoc | Add-Member -NotePropertyName 'repoUrl' -NotePropertyValue $repoUrl
            }
            # BOM-less UTF-8: status.json is served over HTTP to the browser
            # dashboard and the Go aggregator, whose JSON parsers reject a
            # leading BOM. Matches the canonical Write-YurunaStateFile sidecar
            # encoding and the detached server's own status.json writes.
            $statusDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $StatusFile -Encoding utf8
            Write-Output "Set repoUrl in status.json: $repoUrl"
        }
    } catch {
        Write-Warning "Could not update repoUrl in status.json: $_"
    }
}

# --- REGION: Clean up leftovers from older layouts
# server.heartbeat: server no longer reads this; tidy up so inspectors
# don't think it's load-bearing.
# Legacy paths directly under test/status/ and under the old
# test/status/track/ (now test/status/runtime/): older on-disk layouts
# place server.pid, runner.pid, status.json, server.err,
# current-action.json, control.*-pause, .status-service.ps1 in those
# locations. A checkout upgrade can leave those untracked (no longer
# .gitignored), cluttering `git status`. Drop them on every start so
# operator runs land on a clean status dir.
Remove-Item (Join-Path $StatusDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $RuntimeDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue
$LegacyTrackDir = Join-Path $StatusDir 'track'
foreach ($legacyName in @('server.pid','runner.pid','status.json','server.err','current-action.json',
                          'control.pause','control.step-pause','control.cycle-pause','.status-service.ps1')) {
    Remove-Item (Join-Path $StatusDir       $legacyName) -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $LegacyTrackDir  $legacyName) -Force -ErrorAction SilentlyContinue
}
# Drop the entire legacy test/status/track/ tree if it survives a
# checkout upgrade (perf data now lives under status/perf/, runtime
# state under status/runtime/, extension event logs under
# status/extension/...; the old folder is no longer .gitignored).
if (Test-Path -LiteralPath $LegacyTrackDir) {
    Remove-Item -LiteralPath $LegacyTrackDir -Recurse -Force -ErrorAction SilentlyContinue
}
# Stale break-active sidecar / continue flag from a previous run that crashed
# mid-break: clear them so the UI doesn't render a Continue button against a
# break that no longer exists, and the next break doesn't auto-resume on the
# first poll tick.
Remove-Item (Join-Path $RuntimeDir 'break-active.json')      -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $RuntimeDir 'control.break-continue') -Force -ErrorAction SilentlyContinue

# --- REGION: Enumerate host IPs → $env:YURUNA_RUNTIME_DIR/ipaddresses.txt
# UI footer reads this to show reachable addresses. Loopback
# (127.0.0.1, ::1) excluded — useless for remote clients.
#
# File format:
#   * No addresses  → single line "No IP addresses detected"
#   * Addresses     → up to two lines:
#       line 1: IPv4, comma-separated (omitted if none)
#       line 2: IPv6, comma-separated (omitted if none)
#
# Split IPv4/IPv6 so the UI renders two short rows instead of one long
# run. File is overwritten on every Start-StatusService invocation so
# stale entries from a previous host/network are not preserved.
$IpAddressesFile = Join-Path $RuntimeDir "ipaddresses.txt"
try {
    $collectedAddresses = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        ForEach-Object { $_.Address } |
        Where-Object { -not [System.Net.IPAddress]::IsLoopback($_) }

    $ipv4 = @($collectedAddresses |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.ToString() } |
        Sort-Object -Unique)
    $ipv6 = @($collectedAddresses |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 } |
        ForEach-Object { $_.ToString() } |
        Sort-Object -Unique)

    if ($ipv4.Count -eq 0 -and $ipv6.Count -eq 0) {
        $fileContent = "No IP addresses detected"
        $reportCount = 0
    } else {
        $lines = @()
        if ($ipv4.Count -gt 0) { $lines += ($ipv4 -join ',') }
        if ($ipv6.Count -gt 0) { $lines += ($ipv6 -join ',') }
        # LF not CRLF — UI splits on \n; single line terminator avoids
        # \r leaking into rendered strings.
        $fileContent = ($lines -join "`n")
        $reportCount = $ipv4.Count + $ipv6.Count
    }
    # UTF-8 without BOM so a browser fetch() yields a clean string.
    [System.IO.File]::WriteAllText($IpAddressesFile, $fileContent, [System.Text.UTF8Encoding]::new($false))
    Write-Output "IP addresses ($reportCount): written to $IpAddressesFile"
} catch {
    Write-Warning "Failed to enumerate/write IP addresses: $_"
    # Best-effort: leave a previous file intact.
}

# --- REGION: Detect host type
# $detectedHost is captured at parent startup and threaded into the
# detached server's here-string (as $serverHostType) so the per-host
# folder lookup at /control/guest-folders can find host/<short>/guest.*.
$detectedHost = ''
try {
    # Test.HostContract imported by the StatusService kind at file top; Get-HostType
    # is resolvable here without a redundant Import-Module call.
    $detectedHost = Get-HostType
} catch {
    Write-Warning "Host-type detection failed (continuing with HTTP status server): $_"
}

# --- REGION: Probe proxy cache → $env:YURUNA_RUNTIME_DIR/caching-proxy.txt
# UI banner appends this string to the status text so viewers see at a
# glance whether the harness is behind a local squid. File holds
# ready-to-embed HTML (including <a href> to the Grafana dashboards URL) so the UI
# injects it without knowing the URL format. Written once at
# Start-StatusService — restart to refresh after bringing squid up/down.
# Needs $detectedHost, so runs AFTER the SSH block's host detection.
$CachingProxyFile = Join-Path $RuntimeDir "caching-proxy.txt"
try {
    if ($detectedHost) {
        # -Global: this script is &-invoked from the inner cycle runner (a module
        # context), where a -Force import without -Global pulls the host contract
        # out of the global table for foreign modules (the legacy-eviction
        # regression class) -- a contract call made later from Invoke-Sequence
        # would then fail to resolve.
        Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Force -Global
        [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $TestRoot) -HostType $detectedHost)
        # Re-import Test.CachingProxy with -Global -Force here even though
        # the StatusService module set at file top already imported it
        # once: Initialize-YurunaHost cascades
        # into Yuruna.Host.psm1, whose own top-level non-global import of
        # Test.CachingProxy takes over the "one active version per module"
        # slot and evicts this script's view of Read-CachingProxyState.
        # Without this re-import the macOS branch below errors with
        # "The term 'Read-CachingProxyState' is not recognized", the
        # surrounding try catches it, and caching-proxy.txt is left at
        # whatever the prior run wrote -- so the UI banner says "not
        # detected" while the runner's own banner (which goes through
        # Yuruna.Host's session where Read-CachingProxyState IS visible)
        # correctly says "detected". Same shape as Start-CachingProxy.ps1,
        # Stop-CachingProxy.ps1, Repair-CachingProxyForwarder.ps1.
        Import-Module (Join-Path $ModulesDir 'Test.CachingProxy.psm1') -Global -Force -DisableNameChecking -Verbose:$false
        $cachingProxyUrl = Test-CachingProxyAvailable
        if ($cachingProxyUrl) {
            # Port mapping so the status-page banner reports the same
            # state as Invoke-TestRunner's console output.
            # Add-CachingProxyPortMap dispatches per-platform via
            # Test.PortMap (netsh portproxy on Hyper-V, detached
            # TcpListener forwarders on macOS/UTM). Both channels read
            # the same caching-proxy.txt so banner and console stay
            # in lock-step.
            #
            # Windows: port lists across callers MUST match — Add-CachingProxyPortMap
            # runs Clear-AllCachingProxyPortMapping first (netsh clears all), so
            # any port omitted here would be torn down. macOS: per-port pidfiles
            # mean each caller manages its own subset independently; no match
            # required. Port 80 is excluded on macOS (see below).
            #
            # External-cache branch: when $Env:YURUNA_CACHING_PROXY_IP
            # is set, Test-CachingProxyAvailable returns the remote URL and
            # the remote host exposes all its ports itself. Skip the
            # local portproxy/forwarder entirely — the dashboard link
            # points straight at the remote IP.
            $cachingProxyContent = $null
            $mapOk = $false
            $bestIp = $null
            $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_IP
            if ($isExternal) {
                $externUrlIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                # External handling below Remove-PortMaps this host's
                # forwarders, so it may only run when the endpoint is
                # POSITIVELY not this host. 'local': the endpoint is this
                # host's own forwarder set fronting its NAT'd cache VM --
                # removing it severs the listeners that just answered the
                # probe (self-teardown). 'unknown': transient NIC-
                # enumeration gaps must land on the local side, because a
                # wrong 'external' verdict tears the forwarders down while
                # a wrong 'local' verdict merely re-asserts a port map.
                if ($externUrlIp -and ((Get-HostOwnIpVerdict -IpAddress $externUrlIp) -ne 'nonlocal')) {
                    $isExternal = $false
                }
            }
            # Initialize-YurunaHost was already called above; Add-PortMap /
            # Remove-PortMap / Get-BestHostIp are now resolvable via Yuruna.Host.
            if ($true) {
                if ($isExternal) {
                    # Remote serves its own ports; surface the remote IP
                    # in the dashboard link. Clear any stale local
                    # mapping from a prior local-cache cycle.
                    [void](Remove-PortMap -Confirm:$false)
                    $bestIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                    $mapOk = [bool]$bestIp
                } else {
                    # Local-cache port-map target IP: on Windows
                    # Test-CachingProxyAvailable returns the VM's direct
                    # IP (Hyper-V Default Switch is reachable from the
                    # host), so parsing works. On macOS the URL is
                    # http://192.168.64.1:3128 — the VZ-gateway URL
                    # guests use, NOT the cache VM. Feeding 192.168.64.1
                    # to Start-CachingProxyForwarder would make the
                    # forwarder tunnel to its own listen socket (self-
                    # loop: TCP accepts succeed, nothing reaches squid,
                    # subiquity sees "Connection failed [IP: 192.168.64.1
                    # 3128]" and falls back to offline install). Read
                    # the real VM IP from the yuruna-caching-proxy state
                    # file written by Start-CachingProxy.ps1.
                    if ($IsMacOS) {
                        $vmIp = $null
                        $candidate = (Read-CachingProxyState).ipAddress
                        if ($candidate -and (Test-IpAddress $candidate)) { $vmIp = $candidate }
                    } else {
                        $vmIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                        if ($vmIp -and (Test-HostOwnIpAddress -IpAddress $vmIp)) {
                            # Own-address URL (locally-owned cache fronted
                            # by this host's forwarders): the port-map
                            # target must be the cache VM's real IP, never
                            # the host address fronting it (self-loop).
                            $stateVmIp = Get-CachingProxyVMIp
                            if ($stateVmIp) { $vmIp = $stateVmIp }
                        }
                    }
                    # macOS: port 80 (<1024) is managed exclusively by
                    # Start-CachingProxy.ps1 (it calls `sudo -v` first). Including
                    # it here would trigger a sudo prompt on every status-service
                    # restart. On macOS each port is independent (per-port pidfile),
                    # so excluding :80 does not affect the other ports.
                    # Windows: all ports in one list — netsh clears everything first.
                    # All caching-proxy port mappings are repeated in EVERY caller's
                    # list because Add-CachingProxyPortMap clears ALL Yuruna netsh /
                    # pwsh-forwarder / firewall state first; omitting any here
                    # would tear it down each status-service restart.
                    #
                    # Windows External-vSwitch fast path: when the cache
                    # VM is bridged to LAN (its own routable IP), remote
                    # clients reach it directly and squid sees real
                    # client IPs at TCP level. Tear down any prior netsh
                    # mappings so the alternate host:port path doesn't
                    # silently NAT-rewrite a parallel route.
                    # Yuruna.Host's Test-CacheVMOnExternalNetwork checks
                    # for any External-type vSwitch on Windows; on macOS
                    # always returns $true (VMnet shared).
                    $cacheOnExternalSwitch = [bool](Test-CacheVMOnExternalNetwork)
                    if ($cacheOnExternalSwitch) {
                        [void](Remove-PortMap -Confirm:$false)
                        $mapOk = $true
                        $bestIp = $vmIp
                    } elseif ($vmIp -and (Test-HostOwnIpAddress -IpAddress $vmIp)) {
                        # The target resolved no further than one of this
                        # host's own addresses: a forwarder aimed there
                        # would loop each port back onto its own listener.
                        # Keep the port map that is currently serving
                        # traffic instead of replacing it with a loop.
                        $mapOk = $true
                        $bestIp = Get-BestHostIp
                        if (-not $bestIp) { $bestIp = $vmIp }
                    } else {
                        # HTTP/HTTPS port mapping is platform-divergent on the
                        # Default-Switch fallback (see Invoke-TestRunner.ps1
                        # for full rationale): macOS uses pwsh forwarder +
                        # PROXY v1 (real LAN IPs); Windows uses plain netsh
                        # portproxy because the user-mode listener path is
                        # unreachable from LAN on this host (squid logs the
                        # NAT-side IP — see docs/caching.md).
                        # macOS skips :80 — Start-CachingProxy.ps1 is the
                        # sole sudo owner of the privileged bind.
                        # Port values come from YURUNA_CACHING_PROXY_*_PORT
                        # env vars (defaults 3128 / 3129).
                        $cacheHttpPort  = Get-CachingProxyPort -Scheme http
                        $cacheHttpsPort = Get-CachingProxyPort -Scheme https
                        # 9302 (caching-proxy-parser live tail) must stay in
                        # lockstep with Start-CachingProxy.ps1's install list:
                        # Add-PortMap is clear-all-first, so any port omitted
                        # here goes dark on reinstall.
                        $squidPorts = if ($IsMacOS) { @(3000) } else { @(80, 3000, 9302, $cacheHttpPort, $cacheHttpsPort) }
                        if ($vmIp) {
                            $portMapArgs = @{
                                VMIp = $vmIp
                                Port = $squidPorts
                                PortRemap = @{ 8022 = 22 }
                            }
                            if ($IsMacOS) {
                                $portMapArgs.PortRemap[$cacheHttpPort]  = 3138
                                $portMapArgs.PortRemap[$cacheHttpsPort] = 3139
                                $portMapArgs.ProxyProtocolPort          = @($cacheHttpPort, $cacheHttpsPort)
                            }
                            $mapResult = Add-PortMap @portMapArgs -Confirm:$false
                            $mapOk = [bool]$mapResult
                        }
                        if ($mapOk) {
                            $bestIp = Get-BestHostIp
                            if (-not $bestIp) { $bestIp = $vmIp }  # routable-iface fallback
                        }
                    }
                }
            }
            if ($mapOk) {
                $dashboardUrl = "http://${bestIp}:3000/dashboards?tag=yuruna"
                # Escape & for strict HTML-attribute correctness — we
                # inject via .innerHTML so lenient parsers work either
                # way, but strict ones trip on bare `&` next to
                # entity-like sequences.
                $hrefUrl = $dashboardUrl -replace '&', '&amp;'
                $cachingProxyContent = 'Caching proxy: <a href="' + $hrefUrl + '" target="_blank">detected</a>'
                Write-Output "Caching proxy: detected, port map OK, dashboard=$dashboardUrl — written to $CachingProxyFile"
            } else {
                $cachingProxyContent = 'Caching proxy: detected (port map failed)'
                Write-Output "Caching proxy: detected, port map failed — written to $CachingProxyFile"
            }
        } else {
            $cachingProxyContent = 'Caching proxy: not detected'
            Write-Output "Caching proxy: not detected — written to $CachingProxyFile"
        }
        [System.IO.File]::WriteAllText($CachingProxyFile, $cachingProxyContent, [System.Text.UTF8Encoding]::new($false))
    } else {
        Write-Warning "Proxy-cache probe skipped — module missing or host not detected."
    }
} catch {
    Write-Warning "Failed to probe/write proxy-cache state: $_"
    # Best-effort: leave a previous file intact if there was one.
}

# --- REGION: Launch the server as a detached process
$serverScript = @"
`$ErrorActionPreference = 'Stop'
`$listener = [System.Net.HttpListener]::new()
`$listener.Prefixes.Add('http://*:$Port/')
`$statusDir = '$($StatusDir -replace "'","''")'
`$runtimeDir  = '$($RuntimeDir  -replace "'","''")'
`$logDir    = '$($LogDir    -replace "'","''")'
`$repoRoot  = '$($RepoRoot  -replace "'","''")'
# Test-IpAddress and Get-CachingProxyPort are used to validate
# vmStart.cachingProxyIP at save time in /control/test-config. Detached
# server runspace is fresh -- import the module that exports them.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Invoke-CachingProxyProbe (used by /control/test-caching-proxy) lives in
# Test.CachingProxy.psm1. The parent process imports it for its startup
# probe, but the detached child has its own fresh runspace.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.CachingProxy.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Read-TestConfig (mtime+hash cached YAML parse) for the test-config GET
# and perf-aggregates handlers. Same cache the runner uses, so an
# operator edit to test.config.yml is observed on the very next handler
# call without restarting the server.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.Config.psm1')      -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Get-PoolStorageServerName (used by /control/host-aliases) shares the
# networkStorage path grammar with the mount code, so the alias endpoint
# and the mount can never disagree on which token is the server name.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.PoolStorage.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Test-ConfigSyncProof / Protect-ConfigSyncCredential (used by
# /control/vault-credential) live with their client-side counterparts in
# one module so the two ends of the shared-token envelope cannot drift.
# Test.Extension supplies Import-Extension for the lazy authentication-
# extension load inside that route.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.HostConfigSync.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.Extension.psm1')      -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
`$stepPauseFile  = Join-Path `$runtimeDir 'control.step-pause'
`$cyclePauseFile = Join-Path `$runtimeDir 'control.cycle-pause'
`$statusJsonFile = Join-Path `$runtimeDir 'status.json'
`$serverLogFile  = Join-Path `$runtimeDir 'server.err'
# `$serverHostType is the parent-detected host type baked into the
# detached server's here-string. Used by /control/guest-folders to list
# guests under host/<short>/.
`$serverHostType = '$detectedHost'
# NOTE: deliberately NO self-exit on a stale server.heartbeat —
# legitimate runner states outlast ANY threshold: a
# prompt-for-confirmation pausing the runner for hours, or a single
# waitForText with timeoutSeconds:3600. UI must stay up, so the ONLY
# stop path is Stop-StatusService.ps1 (kills server.pid). A truly
# orphaned server must be killed manually — deliberate trade-off.
# Log per-iteration exceptions so we can see why the server died. On
# Windows, Start-Process -WindowStyle Hidden has no stderr redirection,
# so without this file an unhandled throw dies silently — the exact
# prior failure mode where the server vanished mid-run with no trace.
# Bounded so it can't fill the status dir indefinitely.
function Write-ServerErr {
    param([string]`$msg)
    try {
        if ((Test-Path `$serverLogFile) -and ((Get-Item `$serverLogFile).Length -gt 1MB)) {
            Move-Item -Path `$serverLogFile -Destination "`$serverLogFile.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path `$serverLogFile -Value "[`$(Get-Date -Format o)] `$msg" -ErrorAction SilentlyContinue
    } catch { Write-Debug `$_ }
}
try {
    `$listener.Start()
    Write-ServerErr "listener started on http://*:$Port/ (pid `$PID)"
    Write-ServerErr "server hostType='`$serverHostType'"
    # Cross-request memoized per-sequence aggregates served at
    # /control/perf-aggregates. Cleared on POST to that endpoint.
    # `$perfAggregatesBytes holds the serialized response so a GET on an
    # already-built cache skips ConvertTo-Json + GetBytes entirely.
    `$perfAggregatesCache = `$null
    `$perfAggregatesBytes = `$null
    while (`$listener.IsListening) {
      # Outer try/catch: any throw below MUST NOT kill the server.
      # `$listener.EndGetContext(...)` MUST stay inside this try, since
      # transient HttpListenerException (client reset, malformed request,
      # http.sys hiccup) would otherwise unwind to the outer try/finally
      # and exit with no log. Wrap the whole iteration; log + continue.
      try {
        # Block indefinitely for the next request. The server has no
        # self-exit timer, so no periodic wake-up is needed.
        `$ctx = `$listener.GetContext()
        try {
            `$req  = `$ctx.Request
            `$res  = `$ctx.Response
            `$res.Headers.Add('Access-Control-Allow-Origin', '*')
            `$path = `$req.Url.LocalPath.TrimStart('/')
            if (`$path -eq '' -or `$path -eq 'status/' -or `$path -eq 'status') { `$path = 'index.html' }
            `$path = `$path -replace '^status[/\\]', ''

            # --- REGION: /control/test-config: read/write test.config.yml from UI
            # GET parses the YAML on disk and sends it as JSON (200) so the
            # in-browser tree editor (test.config.html) does not need a YAML
            # parser. POST/PUT accepts a JSON body, validates that
            # ConvertFrom-Json parses it, converts to YAML, and atomically
            # replaces the file (write .tmp + Move-Item). Bypasses the
            # /yuruna-repo/ deny-list because the operator has explicitly
            # opted into editing this file from the UI; the response is
            # no-store. All errors come back as {"ok":false,"error":...}.
            # The deny-list still applies to the read-only repo route, so
            # curl GET /yuruna-repo/test/test.config.yml continues to 403.
            if (`$path -eq 'control/test-config') {
                `$testConfigFile = Join-Path `$repoRoot 'test/test.config.yml'
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -eq 'GET' -or `$req.HttpMethod -eq 'HEAD') {
                    if (-not (Test-Path -LiteralPath `$testConfigFile)) {
                        `$res.StatusCode = 404
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"test.config.yml not found"}')
                        `$res.ContentLength64 = `$body.Length
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    try {
                        `$doc  = Read-TestConfig -Path `$testConfigFile -ThrowOnError
                        `$json = `$doc | ConvertTo-Json -Depth 20
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$json)
                    } catch {
                        `$res.StatusCode = 500
                        `$errMsg = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"YAML parse failed: ' + `$errMsg + '"}')
                    }
                    `$res.ContentLength64 = `$bytes.Length
                    if (`$req.HttpMethod -ne 'HEAD') {
                        `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                    }
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$req.HttpMethod -eq 'POST' -or `$req.HttpMethod -eq 'PUT') {
                    `$payload = `$null
                    # ContentLength64 == -1 means chunked/unknown; allow those through.
                    if (`$req.ContentLength64 -gt 1MB) {
                        `$res.StatusCode = 413
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"payload too large (>1 MB)"}')
                        `$res.ContentLength64 = `$body.Length
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    try {
                        `$reader = [System.IO.StreamReader]::new(`$req.InputStream, `$req.ContentEncoding)
                        `$payload = `$reader.ReadToEnd()
                        `$reader.Close()
                    } catch {
                        `$res.StatusCode = 400
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"could not read body"}')
                        `$res.ContentLength64 = `$body.Length
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    `$parsedDoc = `$null
                    try {
                        `$parsedDoc = `$payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    } catch {
                        `$res.StatusCode = 400
                        `$errMsg = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"invalid JSON: ' + `$errMsg + '"}')
                        `$res.ContentLength64 = `$body.Length
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    # Validate vmStart.cachingProxyIP at save time: must be
                    # a valid IPv4/IPv6 address AND TCP-reachable on the
                    # squid HTTP port (3128). Empty/whitespace -> stored as
                    # empty (cycle-start treats empty as absent). Either
                    # failure returns 400 so the UI surfaces the problem
                    # immediately instead of the operator discovering it at
                    # cycle start.
                    `$cacheIpErr = `$null
                    if (`$parsedDoc -is [System.Collections.IDictionary] -and `$parsedDoc.Contains('vmStart')) {
                        `$vsNode = `$parsedDoc['vmStart']
                        if (`$vsNode -is [System.Collections.IDictionary] -and `$vsNode.Contains('cachingProxyIP')) {
                            `$cacheIp = "`$(`$vsNode['cachingProxyIP'])".Trim()
                            `$vsNode['cachingProxyIP'] = `$cacheIp
                            if (`$cacheIp) {
                                if (-not (Get-Command Test-IpAddress -ErrorAction SilentlyContinue)) {
                                    `$cacheIpErr = "Test-IpAddress not available in this runspace -- cannot validate vmStart.cachingProxyIP"
                                } elseif (-not (Test-IpAddress `$cacheIp)) {
                                    `$cacheIpErr = "vmStart.cachingProxyIP='`$cacheIp' is not a valid IPv4 or IPv6 address"
                                } else {
                                    `$cachePort = Get-CachingProxyPort -Scheme http
                                    `$probeTcp = New-Object System.Net.Sockets.TcpClient
                                    `$probeOk  = `$false
                                    try {
                                        `$probeAsync = `$probeTcp.BeginConnect(`$cacheIp, `$cachePort, `$null, `$null)
                                        `$probeOk    = (`$probeAsync.AsyncWaitHandle.WaitOne(1500) -and `$probeTcp.Connected)
                                    } catch {
                                        Write-ServerErr "save-time cachingProxyIP probe `${cacheIp}:`${cachePort} threw: `$(`$_.Exception.Message)"
                                    } finally {
                                        `$probeTcp.Close()
                                    }
                                    if (-not `$probeOk) {
                                        `$cacheIpErr = "vmStart.cachingProxyIP='`$cacheIp' is not reachable on TCP :`$cachePort"
                                    }
                                }
                            }
                        }
                    }
                    if (`$cacheIpErr) {
                        `$res.StatusCode = 400
                        `$errMsg = (`$cacheIpErr -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + `$errMsg + '"}')
                        `$res.ContentLength64 = `$body.Length
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    `$tmp = "`$testConfigFile.tmp"
                    `$writeOk = `$false
                    try {
                        # Written in the JSON body's key/element order (NOT canonical
                        # alphabetical). That is intentional: Sync-TestConfigToTemplate /
                        # Update-TestConfigFromTemplate reconcile this file to canonical
                        # sorted order (and prune orphans) on the next Test-Config run /
                        # cycle start, and every reader parses via ConvertFrom-Yaml, which
                        # is order-insensitive -- so the UI save does not need to sort here.
                        `$yamlOut = `$parsedDoc | ConvertTo-Yaml
                        Set-Content -LiteralPath `$tmp -Value `$yamlOut -Encoding utf8 -NoNewline
                        Move-Item -LiteralPath `$tmp -Destination `$testConfigFile -Force
                        `$writeOk = `$true
                    } catch {
                        `$res.StatusCode = 500
                        `$errMsg = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"write failed: ' + `$errMsg + '"}')
                        `$res.ContentLength64 = `$body.Length
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        Write-ServerErr "test-config write failed: `$errMsg"
                    } finally {
                        # On the failure path, Set-Content may have left
                        # a partial .tmp next to the real file; on the
                        # success path Move-Item already consumed it.
                        # Either way, ensure no .tmp is left behind.
                        if (-not `$writeOk -and (Test-Path -LiteralPath `$tmp)) {
                            Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue
                        }
                    }
                    if (-not `$writeOk) { continue }
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.StatusCode = 405
                `$res.Headers.Add('Allow', 'GET, POST, PUT')
                `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed"}')
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/runtime-env: surface specific env vars to the UI
            # Read-only GET endpoint. Currently emits one key,
            # YURUNA_CACHING_PROXY_IP, so the test-config editor can show
            # the env value side-by-side with the persisted
            # vmStart.cachingProxyIP. Value reflects the server process's
            # env (snapshotted at server start when this pwsh inherited
            # its parent's env block) -- separate from the value that an
            # Invoke-TestRunner.ps1 inner runspace might see if it was
            # launched from a different shell. Caveat documented in the
            # UI tooltip on the read-only field.
            if (`$path -eq 'control/runtime-env') {
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'GET')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$envValue = if (`$env:YURUNA_CACHING_PROXY_IP) { `$env:YURUNA_CACHING_PROXY_IP } else { '' }
                # [Environment]::UserName returns the effective user the
                # status-service process is running as. Cross-platform: on
                # Windows it's the (possibly space-containing) display name
                # like "Yuruna Test"; on macOS / Linux it's the short
                # username like "alissonsol". Surfaced so the test.config
                # banner can show which account the operator's session is
                # actually under (useful when sudo / Run-As elevation is
                # in play, or on a host with multiple operator accounts).
                `$serverUser = try { [Environment]::UserName } catch { '' }
                `$payload = @{
                    YURUNA_CACHING_PROXY_IP = `$envValue
                    serverUserAccount = `$serverUser
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/perf-aggregates: per-sequence cycle durations for perf.html
            # GET  -> cached aggregates (computes on first call).
            # POST -> clear the cache then return fresh aggregates.
            if (`$path -eq 'control/perf-aggregates') {
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'GET, POST')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$req.HttpMethod -eq 'POST') {
                    `$perfAggregatesCache = `$null
                    `$perfAggregatesBytes = `$null
                }
                if (`$null -eq `$perfAggregatesCache) {
                    # Same cap that bounds status.json's history[] (the
                    # "Recent Cycles" list on the dashboard). Read from
                    # test.config.yml so the constant lives in exactly
                    # one place; Invoke-TestInnerRunner uses the same
                    # path for its Complete-Run -MaxHistoryRuns.
                    `$recentLimit = 30
                    try {
                        `$testConfigFile = Join-Path `$repoRoot 'test/test.config.yml'
                        `$doc = Read-TestConfig -Path `$testConfigFile
                        if (`$doc -and (`$doc.testCycle -is [System.Collections.IDictionary]) -and `$doc.testCycle.Contains('recentDisplayCount')) {
                            `$v = [int]`$doc.testCycle.recentDisplayCount
                            if (`$v -gt 0) { `$recentLimit = `$v }
                        }
                    } catch {
                        Write-ServerErr "perf-aggregates: could not read recentDisplayCount: `$(`$_.Exception.Message)"
                    }
                    `$cyclesDir = Join-Path `$statusDir 'perf/cycles'
                    `$sequences = @{}
                    if (Test-Path -LiteralPath `$cyclesDir) {
                        # JSONL file names lead with the cycle's ISO-8601
                        # timestamp (colons -> hyphens, but the lexical
                        # order still matches chronological order). Name-
                        # descending sort + take-N = the latest N cycles
                        # = the same set the dashboard's history[] shows.
                        `$jsonlFiles = @(Get-ChildItem -LiteralPath `$cyclesDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                                          Sort-Object Name -Descending |
                                          Select-Object -First `$recentLimit)
                        foreach (`$f in `$jsonlFiles) {
                            try {
                                `$reader = [System.IO.StreamReader]::new(`$f.FullName)
                                try {
                                    while (-not `$reader.EndOfStream) {
                                        `$line = `$reader.ReadLine()
                                        if ([string]::IsNullOrWhiteSpace(`$line)) { continue }
                                        try { `$row = `$line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                                        if (-not `$row.sequenceName -or -not `$row.cycleId) { continue }
                                        `$seq = "`$(`$row.sequenceName)"
                                        `$cyc = "`$(`$row.cycleId)"
                                        if (-not `$sequences.ContainsKey(`$seq)) { `$sequences[`$seq] = @{} }
                                        `$bag = `$sequences[`$seq]
                                        if (-not `$bag.ContainsKey(`$cyc)) {
                                            `$bag[`$cyc] = [ordered]@{
                                                cycleId           = `$cyc
                                                cycleStartedAtUtc = "`$(`$row.cycleStartedAtUtc)"
                                                hostPlatform      = "`$(`$row.hostPlatform)"
                                                guestKey          = "`$(`$row.guestKey)"
                                                durationMs        = 0
                                                stepCount         = 0
                                                failCount         = 0
                                                steps             = (New-Object System.Collections.ArrayList)
                                            }
                                        }
                                        `$agg = `$bag[`$cyc]
                                        `$ms = 0
                                        try { `$ms = [int]`$row.durationMs } catch { `$ms = 0 }
                                        `$agg.durationMs = [int]`$agg.durationMs + `$ms
                                        `$agg.stepCount  = [int]`$agg.stepCount + 1
                                        if ("`$(`$row.outcome)" -eq 'fail') { `$agg.failCount = [int]`$agg.failCount + 1 }
                                        `$ord = 0; try { `$ord = [int]`$row.stepOrdinal    } catch { `$ord = 0 }
                                        `$occ = 1; try { `$occ = [int]`$row.stepOccurrence } catch { `$occ = 1 }
                                        `$prnt = 0; try { `$prnt = [int]`$row.parentStepOrdinal } catch { `$prnt = 0 }
                                        # Absolute step window as epoch-ms integers. perf.html derives
                                        # the step hierarchy from these windows (a retry parent's
                                        # window brackets its child steps) and draws each cycle as a
                                        # time-based icicle, so nested time is shown once instead of
                                        # the parent being stacked on top of its children. Emitted as
                                        # numbers (not the .NET 'o' ISO string) so the browser never
                                        # has to parse 7-digit fractional-second timestamps.
                                        `$sMs = `$null; `$eMs = `$null
                                        try { `$sMs = [DateTimeOffset]::Parse(`$row.startedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUnixTimeMilliseconds() } catch { `$sMs = `$null }
                                        try { `$eMs = [DateTimeOffset]::Parse(`$row.endedAtUtc,   [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUnixTimeMilliseconds() } catch { `$eMs = `$null }
                                        `$stepEntry = [ordered]@{
                                            ordinal       = `$ord
                                            occurrence    = `$occ
                                            name          = "`$(`$row.stepName)"
                                            kind          = "`$(`$row.stepKind)"
                                            durationMs    = `$ms
                                            outcome       = "`$(`$row.outcome)"
                                            parentOrdinal = `$prnt
                                            parentAction  = "`$(`$row.parentAction)"
                                            startedMs     = `$sMs
                                            endedMs       = `$eMs
                                        }
                                        # fetchAndExecute steps also keep the ISO [start,end] window:
                                        # guest-pushed checkpoint sidecars are joined to them by
                                        # matching receivedAtUtc against this window.
                                        if ("`$(`$row.stepKind)" -eq 'fetchAndExecute') {
                                            `$stepEntry.startedAtUtc = "`$(`$row.startedAtUtc)"
                                            `$stepEntry.endedAtUtc   = "`$(`$row.endedAtUtc)"
                                        }
                                        `$null = `$agg.steps.Add(`$stepEntry)
                                    }
                                } finally { `$reader.Close() }
                            } catch {
                                Write-ServerErr "perf-aggregates: failed to read `$(`$f.FullName): `$(`$_.Exception.Message)"
                            }
                        }
                    }
                    # Load recent guest-pushed checkpoint sidecars once. Each is
                    # joined to the fetchAndExecute step whose [start,end] window
                    # contains its host-stamped receivedAtUtc (host clock both
                    # sides -> skew-immune). Newest-first so a window holding more
                    # than one sidecar prefers the latest; Consumed stops two
                    # steps claiming the same one.
                    `$ckptDir2 = Join-Path `$statusDir 'perf/checkpoints'
                    `$ckptSidecars = New-Object System.Collections.ArrayList
                    if (Test-Path -LiteralPath `$ckptDir2) {
                        `$scFiles = @(Get-ChildItem -LiteralPath `$ckptDir2 -Filter '*.json' -File -ErrorAction SilentlyContinue |
                                       Sort-Object Name -Descending | Select-Object -First 1000)
                        foreach (`$sc in `$scFiles) {
                            try {
                                `$scDoc = Get-Content -LiteralPath `$sc.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                            } catch { continue }
                            if (-not `$scDoc.receivedAtUtc) { continue }
                            `$rcvd = [DateTime]::MinValue
                            try {
                                `$rcvd = [DateTime]::Parse(`$scDoc.receivedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                            } catch { continue }
                            `$null = `$ckptSidecars.Add([pscustomobject]@{
                                ReceivedAt  = `$rcvd
                                Checkpoints = `$scDoc.checkpoints
                                Consumed    = `$false
                            })
                        }
                    }
                    `$out = [ordered]@{}
                    foreach (`$seq in (`$sequences.Keys | Sort-Object)) {
                        `$cyclesArr = @(`$sequences[`$seq].Values | Sort-Object { "`$(`$_.cycleStartedAtUtc)" })
                        # Sort each cycle's steps in execution order so the
                        # stacked-bar segments render bottom-to-top in the order
                        # the runner ran them, then splice any matching checkpoint
                        # sidecar onto the fetchAndExecute steps.
                        foreach (`$cyc2 in `$cyclesArr) {
                            `$sortedSteps = @(`$cyc2.steps | Sort-Object @{Expression='ordinal'},@{Expression='occurrence'})
                            foreach (`$st2 in `$sortedSteps) {
                                if ("`$(`$st2.kind)" -ne 'fetchAndExecute') { continue }
                                if (-not `$st2.Contains('startedAtUtc') -or -not `$st2.Contains('endedAtUtc')) { continue }
                                `$sUtc = [DateTime]::MinValue; `$eUtc = [DateTime]::MinValue
                                try {
                                    `$sUtc = [DateTime]::Parse(`$st2.startedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                    `$eUtc = [DateTime]::Parse(`$st2.endedAtUtc,   [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                } catch { continue }
                                foreach (`$cand in `$ckptSidecars) {
                                    if (`$cand.Consumed) { continue }
                                    if (`$cand.ReceivedAt -ge `$sUtc -and `$cand.ReceivedAt -le `$eUtc) {
                                        `$cand.Consumed = `$true
                                        `$st2.checkpoints = @(`$cand.Checkpoints)
                                        break
                                    }
                                }
                            }
                            `$cyc2.steps = `$sortedSteps
                        }
                        `$out[`$seq] = `$cyclesArr
                    }
                    `$perfAggregatesCache = [ordered]@{
                        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                        recentLimit    = `$recentLimit
                        sequences      = `$out
                    }
                    # Serialize once on (re)build; every subsequent GET writes
                    # these bytes directly. Depth 8: payload -> sequences ->
                    # cycles[] -> cycle -> steps[] -> step -> checkpoints[] ->
                    # checkpoint{name,offsetMs}; the checkpoint objects sit one
                    # level deeper than the rest, so a shallower depth would
                    # stringify them and drop name/offsetMs.
                    `$json = `$perfAggregatesCache | ConvertTo-Json -Depth 8 -Compress
                    `$perfAggregatesBytes = [System.Text.Encoding]::UTF8.GetBytes(`$json)
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$res.ContentLength64 = `$perfAggregatesBytes.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$perfAggregatesBytes, 0, `$perfAggregatesBytes.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/perf-checkpoints: guest-pushed fetch-and-execute phase timings
            # fetch-and-execute.sh POSTs the ==== checkpoint ==== markers it
            # collected while running a fetched script. We host-stamp the arrival
            # time -- that timestamp is the join key: perf-aggregates matches it
            # against the fetchAndExecute step's [start,end] window. Both sides of
            # that comparison are host-clock, so guest/host clock skew can never
            # break the match. The sidecar filename is minted here, never taken
            # from the body, so nothing in the payload can traverse the path.
            if (`$path -eq 'control/perf-checkpoints') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed; POST the checkpoint body"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$req.ContentLength64 -gt 256KB) {
                    `$res.StatusCode = 413
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"payload too large (>256 KB)"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$rawBody = ''
                try {
                    `$reader = [System.IO.StreamReader]::new(`$req.InputStream, `$req.ContentEncoding)
                    try { `$rawBody = `$reader.ReadToEnd() } finally { `$reader.Close() }
                } catch { `$rawBody = '' }
                `$parsed = `$null
                try { `$parsed = `$rawBody | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { `$parsed = `$null }
                if (`$null -eq `$parsed -or -not (`$parsed -is [System.Collections.IDictionary])) {
                    `$res.StatusCode = 400
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"body must be a JSON object"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                # Bounded, validated copy of the checkpoint list (max 500;
                # name <= 200 chars; offsetMs a non-negative int). Off-shape
                # entries are dropped, not rejected, so a partial run still
                # records the checkpoints it did capture.
                `$cleanCkpts = New-Object System.Collections.ArrayList
                if (`$parsed.Contains('checkpoints') -and (`$parsed.checkpoints -is [System.Collections.IEnumerable])) {
                    foreach (`$ck in `$parsed.checkpoints) {
                        if (`$cleanCkpts.Count -ge 500) { break }
                        if (-not (`$ck -is [System.Collections.IDictionary])) { continue }
                        `$nm = ''
                        if (`$ck.Contains('name') -and `$null -ne `$ck.name) { `$nm = [string]`$ck.name }
                        if (`$nm.Length -gt 200) { `$nm = `$nm.Substring(0, 200) }
                        if ([string]::IsNullOrWhiteSpace(`$nm)) { continue }
                        `$off = 0
                        try { `$off = [int]`$ck.offsetMs } catch { `$off = 0 }
                        if (`$off -lt 0) { `$off = 0 }
                        `$null = `$cleanCkpts.Add([ordered]@{ name = `$nm; offsetMs = `$off })
                    }
                }
                `$scriptPathIn = ''
                if (`$parsed.Contains('scriptPath') -and `$null -ne `$parsed.scriptPath) { `$scriptPathIn = [string]`$parsed.scriptPath }
                if (`$scriptPathIn.Length -gt 400) { `$scriptPathIn = `$scriptPathIn.Substring(0, 400) }
                `$srcTag = ''
                if (`$parsed.Contains('source') -and `$null -ne `$parsed.source) { `$srcTag = [string]`$parsed.source }
                `$guestHost = ''
                if (`$parsed.Contains('hostname') -and `$null -ne `$parsed.hostname) { `$guestHost = [string]`$parsed.hostname }
                `$ckptExit = 0
                try { if (`$parsed.Contains('exitCode')) { `$ckptExit = [int]`$parsed.exitCode } } catch { `$ckptExit = 0 }
                `$remoteIp = ''
                try { `$remoteIp = `$req.RemoteEndPoint.Address.ToString() } catch { `$remoteIp = '' }

                `$receivedUtc = [DateTime]::UtcNow.ToString('o')
                `$sidecar = [ordered]@{
                    schema        = 1
                    receivedAtUtc = `$receivedUtc
                    remoteIp      = `$remoteIp
                    scriptPath    = `$scriptPathIn
                    source        = `$srcTag
                    hostname      = `$guestHost
                    exitCode      = `$ckptExit
                    checkpoints   = @(`$cleanCkpts)
                }

                `$ckptDir = Join-Path `$statusDir 'perf/checkpoints'
                `$writeOk = `$false
                try {
                    if (-not (Test-Path -LiteralPath `$ckptDir)) {
                        `$null = New-Item -ItemType Directory -Path `$ckptDir -Force -ErrorAction SilentlyContinue
                    }
                    # ':' is illegal in Windows filenames, so the ISO arrival
                    # stamp gets colons -> hyphens (same transform Test.Perf uses
                    # for cycle JSONL names); the receivedAtUtc field inside keeps
                    # the untouched ISO for the window comparison.
                    `$safeStamp   = `$receivedUtc -replace ':', '-'
                    `$tail        = ([Guid]::NewGuid().ToString('N')).Substring(0, 4)
                    `$ckptFile    = Join-Path `$ckptDir "`${safeStamp}__`${tail}.json"
                    `$tmpFile     = "`$ckptFile.tmp"
                    `$sidecarJson = `$sidecar | ConvertTo-Json -Depth 6 -Compress
                    [System.IO.File]::WriteAllText(`$tmpFile, `$sidecarJson)
                    Move-Item -LiteralPath `$tmpFile -Destination `$ckptFile -Force
                    `$writeOk = `$true
                    # Light retention: keep the newest ~500 sidecars so the
                    # directory can't grow without bound across many cycles.
                    `$allCkpts = @(Get-ChildItem -LiteralPath `$ckptDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                    if (`$allCkpts.Count -gt 500) {
                        foreach (`$old in (`$allCkpts | Select-Object -Skip 500)) {
                            Remove-Item -LiteralPath `$old.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                } catch {
                    Write-ServerErr "perf-checkpoints: write failed: `$(`$_.Exception.Message)"
                }
                if (-not `$writeOk) {
                    `$res.StatusCode = 500
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"sidecar write failed"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                # Fresh checkpoint data invalidates the memoized aggregates so the
                # next GET re-runs the join (mirrors the POST-recalc invalidation).
                `$perfAggregatesCache = `$null
                `$perfAggregatesBytes = `$null
                `$payloadOut = '{"ok":true,"checkpoints":' + `$cleanCkpts.Count + '}'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payloadOut)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/test-caching-proxy?ip=<ip>: probe a caching proxy from the host
            # Wraps Invoke-CachingProxyProbe (Test.CachingProxy.psm1, same
            # function the startup probe uses) so the test-config UI can
            # show a live connectivity verdict next to cachingProxyIP and
            # the `$env:YURUNA_CACHING_PROXY_IP mirror. UI debounces input;
            # the probe itself is sync (~few seconds: 4 TCP probes with
            # 1.5s timeouts + a 5s CA-cert HTTP fetch). Empty/invalid IP
            # returns valid=false WITHOUT running the probe so the UI can
            # render a "disabled" mark instead of a false negative.
            if (`$path -eq 'control/test-caching-proxy') {
                if (`$req.HttpMethod -ne 'GET') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'GET')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$ipQ = `$req.QueryString['ip']
                if (`$null -eq `$ipQ) { `$ipQ = '' }
                `$ipQ = "`$ipQ".Trim()
                `$ipValid = `$false
                if (`$ipQ) {
                    try { `$ipValid = [bool](Test-IpAddress `$ipQ) } catch { `$ipValid = `$false }
                }
                if (-not `$ipValid) {
                    `$payload = [pscustomobject]@{
                        ok                 = `$true
                        ip                 = `$ipQ
                        valid              = `$false
                        success            = `$false
                        httpProxyReachable = `$false
                        passCount          = 0
                        warnCount          = 0
                        failCount          = 0
                        lines              = @()
                    } | ConvertTo-Json -Compress -Depth 4
                } else {
                    try {
                        `$probe = Invoke-CachingProxyProbe -CacheIp `$ipQ -CacheSource 'status-service /control/test-caching-proxy'
                        `$payload = [pscustomobject]@{
                            ok                 = `$true
                            ip                 = `$ipQ
                            valid              = `$true
                            success            = [bool]`$probe.Success
                            httpProxyReachable = [bool]`$probe.HttpProxyReachable
                            passCount          = [int]`$probe.PassCount
                            warnCount          = [int]`$probe.WarnCount
                            failCount          = [int]`$probe.FailCount
                            lines              = @(`$probe.Lines)
                        } | ConvertTo-Json -Compress -Depth 4
                    } catch {
                        `$errMsg = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        `$payload = '{"ok":false,"ip":"' + (`$ipQ -replace '\\','\\' -replace '"','\"') + '","valid":true,"error":"' + `$errMsg + '"}'
                        Write-ServerErr "test-caching-proxy probe failed for `${ipQ}: `$errMsg"
                    }
                }
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/guest-folders: list guest.* dirs under current host
            # Powers the test-config editor's guestSequence dropdown so the
            # operator picks from real folders instead of free-typing a
            # name that won't match anything at run time. Host folder is
            # derived from the host type captured at server startup
            # (host.windows.hyper-v -> host/windows.hyper-v); empty array
            # is returned when the host is unknown or has no guests.
            if (`$path -eq 'control/guest-folders') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$guests = @()
                if (`$serverHostType) {
                    `$hostFolderName = `$serverHostType -replace '^host\.', ''
                    `$hostPath = Join-Path `$repoRoot ('host/' + `$hostFolderName)
                    if (Test-Path -LiteralPath `$hostPath) {
                        `$guests = @(Get-ChildItem -LiteralPath `$hostPath -Directory -Filter 'guest.*' -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty Name | Sort-Object)
                    }
                }
                # Build the JSON array literally: ConvertTo-Json's
                # array-vs-scalar handling is brittle on PowerShell 7
                # (-AsArray + -InputObject double-wraps an existing
                # array, plain pipe drops the empty case to nothing).
                # Folder names are safe ASCII so a hand-built [...]
                # avoids the dance entirely.
                `$items = @(`$guests | ForEach-Object { '"' + (`$_ -replace '\\','\\\\' -replace '"','\"') + '"' })
                `$payload = '[' + (`$items -join ',') + ']'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/runner-status: is Invoke-TestRunner actually alive?
            # Reads <track>/runner.pid (owned by the outer runner) and
            # identifies the process as the outer runner via TWO paths:
            #
            #   1. <track>/runner.start sidecar (preferred): contains the
            #      outer pwsh's ISO-8601 StartTime, recorded at launch.
            #      We cross-check against Get-Process -Id <pid>'s live
            #      StartTime — a PID-reuse by a different process has a
            #      different StartTime, so the check is forgery-resistant
            #      without depending on argv visibility. This is what
            #      makes the documented `pwsh ~/git/yuruna/test/Invoke-
            #      TestRunner.ps1` launch (run from an interactive pwsh
            #      REPL on macOS/Linux) get correctly identified — there
            #      the process's argv is just `pwsh` (no script name),
            #      and the cmdline regex below false-negatives.
            #
            #   2. Cmdline regex (fallback): for older runners without
            #      the sidecar and for launches that DO carry the script
            #      in argv (Windows shortcut, `pwsh -File ...`). Uses the
            #      same regex the outer runner uses itself for stale-PID
            #      detection at startup.
            #
            # Returns: { running: bool, pid: int|null }
            # The UI shows a "Stopped" banner when running=false so the
            # operator isn't fooled by status.json showing the last
            # cycle's data into thinking the runner is still active.
            if (`$path -eq 'control/runner-status') {
                `$running = `$false
                `$pidVal  = `$null
                `$runnerPidFile   = Join-Path `$runtimeDir 'runner.pid'
                `$runnerStartFile = Join-Path `$runtimeDir 'runner.start'
                if (Test-Path -LiteralPath `$runnerPidFile) {
                    try {
                        `$rawPid = (Get-Content -LiteralPath `$runnerPidFile -Raw -ErrorAction Stop).Trim()
                        if (`$rawPid -as [int]) {
                            `$pidVal = [int]`$rawPid
                            `$proc = Get-Process -Id `$pidVal -ErrorAction SilentlyContinue
                            if (`$proc) {
                                # Path 1: StartTime cross-check against the sidecar.
                                if (Test-Path -LiteralPath `$runnerStartFile) {
                                    try {
                                        `$recorded   = (Get-Content -LiteralPath `$runnerStartFile -Raw -ErrorAction Stop).Trim()
                                        `$recordedDt = [DateTimeOffset]::Parse(`$recorded).UtcDateTime
                                        `$liveDt     = `$proc.StartTime.ToUniversalTime()
                                        # 2s tolerance absorbs the
                                        # ToString('o') -> Parse round-trip
                                        # precision loss seen on some kernels
                                        # without admitting an unrelated PID.
                                        if ([Math]::Abs((`$recordedDt - `$liveDt).TotalSeconds) -le 2) {
                                            `$running = `$true
                                        }
                                    } catch {
                                        Write-ServerErr "runner.start cross-check failed: `$($_.Exception.Message)"
                                    }
                                }
                                # Path 2: cmdline regex fallback.
                                if (-not `$running) {
                                    `$cmd = `$null
                                    if (`$IsWindows) {
                                        `$cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=`$pidVal" -ErrorAction SilentlyContinue).CommandLine
                                    } elseif (`$IsMacOS -or `$IsLinux) {
                                        # `-ww` forces unlimited column width. Without it,
                                        # BSD/macOS ps truncates `args` to the controlling
                                        # terminal's columns (or 80 if there's no TTY -- the
                                        # case for this HTTP server daemon), hiding the
                                        # trailing `Invoke-TestRunner.ps1` token that the
                                        # regex below matches against.
                                        `$cmd = & '/bin/ps' -ww -p `$pidVal -o args= 2>`$null
                                    }
                                    if (`$cmd -and `$cmd -match 'Invoke-Test(?:Inner)?Runner\.ps1') {
                                        `$running = `$true
                                    }
                                }
                            }
                        }
                    } catch {
                        Write-ServerErr "runner-status read failed: `$($_.Exception.Message)"
                    }
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$payload = @{ running = `$running; pid = `$pidVal } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/host-diagnostic: run Get-SystemDiagnostic on the host
            # --- REGION: https://yuruna.link/definition#defining-the-status-page-hostinfo-dump
            if (`$path -eq 'control/host-diagnostic') {
                `$res.ContentType = 'text/plain; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$diagScript = Join-Path `$repoRoot 'automation/Get-SystemDiagnostic.ps1'
                `$tmpFile    = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-hostinfo.txt'
                `$content    = ''
                try {
                    if (-not (Test-Path -LiteralPath `$diagScript)) {
                        throw "Get-SystemDiagnostic.ps1 not found at `$diagScript"
                    }
                    `$content = & pwsh -NoProfile -ExecutionPolicy Bypass -WorkingDirectory `$repoRoot -File `$diagScript 2>&1 | Out-String
                    Set-Content -LiteralPath `$tmpFile -Value `$content -Encoding utf8 -ErrorAction SilentlyContinue
                } catch {
                    `$content = "Error running Get-SystemDiagnostic.ps1: `$($_.Exception.Message)"
                    Write-ServerErr "host-diagnostic failed: `$($_.Exception.Message)"
                }
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$content)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/host-aliases: networkStorage server names -> IPs as THIS host resolves them
            # Read-only GET. Serves the name->IP resolutions for the server
            # names referenced by this host's networkStorage config (and
            # nothing else -- a full hosts-file dump stays in the diagnostic
            # report). A peer host syncing its config from this one uses it
            # to adopt the alias for a NAS name that does not resolve there
            # (host/<type>/Sync-HostConfiguration.ps1). Names + LAN IPs are
            # not secrets, so the route stays unauthenticated like the rest
            # of the status surface.
            if (`$path -eq 'control/host-aliases') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'GET')
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed"}')
                } elseif (-not (Get-Command Get-PoolStorageServerName -ErrorAction SilentlyContinue) -or
                          -not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                    `$res.StatusCode = 500
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Test.PoolStorage / Test.Config not loaded in the server runspace"}')
                } else {
                    try {
                        `$doc = Read-TestConfig -Path (Join-Path `$repoRoot 'test/test.config.yml') -ThrowOnError
                        `$ns  = if (`$doc -is [System.Collections.IDictionary]) { `$doc['networkStorage'] } else { `$null }
                        `$aliases    = [ordered]@{}
                        `$unresolved = [System.Collections.Generic.List[string]]::new()
                        if (`$ns -is [System.Collections.IDictionary]) {
                            foreach (`$npKey in @('poolNetworkPath', 'stashNetworkPath')) {
                                `$np = if (`$ns.Contains(`$npKey)) { "`$(`$ns[`$npKey])".Trim() } else { '' }
                                if (-not `$np) { continue }
                                `$server = Get-PoolStorageServerName -NetworkPath `$np
                                if (-not `$server -or `$aliases.Contains(`$server) -or `$unresolved.Contains(`$server)) { continue }
                                try {
                                    `$addrs = [System.Net.Dns]::GetHostAddresses(`$server)
                                    `$pick = `$addrs | Where-Object { `$_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                                    if (-not `$pick) { `$pick = `$addrs | Select-Object -First 1 }
                                    if (`$pick) { `$aliases[`$server] = `$pick.ToString() } else { [void]`$unresolved.Add(`$server) }
                                } catch {
                                    [void]`$unresolved.Add(`$server)
                                }
                            }
                        }
                        `$payload = @{ ok = `$true; aliases = `$aliases; unresolved = @(`$unresolved) } | ConvertTo-Json -Compress -Depth 5
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                    } catch {
                        `$res.StatusCode = 500
                        `$errMsg = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + `$errMsg + '"}')
                    }
                }
                `$res.ContentLength64 = `$bytes.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/vault-credential: token-gated networkStorage credential for a peer host
            # GET ?user=<logicalUser>&nonce=<b64>&proof=<b64>. Serves ONE
            # vault password -- and only for a user this host's own
            # networkStorage config references -- to a peer that proves it
            # holds the operator-set shared pool-auth-token (HMAC proof; the
            # token itself never crosses the wire). The response password is
            # AES-GCM encrypted with a key derived from token + user + the
            # client's nonce (Protect-ConfigSyncCredential), so the secret
            # stays confidential over this plain-HTTP listener. Replaying a
            # captured request only re-fetches ciphertext the replayer still
            # cannot decrypt. 503 until the operator configures the shared
            # token (mirrors the aggregator's default-off /ingest gate);
            # never auto-generates a vault entry to serve.
            if (`$path -eq 'control/vault-credential') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$vcStatus = 200
                `$vcError  = `$null
                `$qUser  = `$req.QueryString['user']
                `$qNonce = `$req.QueryString['nonce']
                `$qProof = `$req.QueryString['proof']
                if (`$req.HttpMethod -ne 'GET') {
                    `$vcStatus = 405; `$vcError = 'method not allowed'
                    `$res.Headers.Add('Allow', 'GET')
                } elseif (-not `$qUser -or -not `$qNonce -or -not `$qProof) {
                    `$vcStatus = 400; `$vcError = 'user, nonce and proof query parameters are required'
                } elseif (-not (Get-Command Test-ConfigSyncProof -ErrorAction SilentlyContinue) -or
                          -not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                    `$vcStatus = 500; `$vcError = 'Test.HostConfigSync / Test.Config not loaded in the server runspace'
                }
                if (-not `$vcError) {
                    # Lazy authentication-extension load: the vault only has
                    # to be readable when a peer actually asks.
                    if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
                        try { `$null = Import-Extension -Area 'authentication' -RequireSingle } catch { `$null = `$_ }
                    }
                    if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -or
                        -not (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
                        `$vcStatus = 503; `$vcError = 'authentication extension unavailable'
                    }
                }
                if (-not `$vcError) {
                    try {
                        `$doc = Read-TestConfig -Path (Join-Path `$repoRoot 'test/test.config.yml') -ThrowOnError
                        `$ns  = if (`$doc -is [System.Collections.IDictionary]) { `$doc['networkStorage'] } else { `$null }
                        `$allowed = [System.Collections.Generic.List[string]]::new()
                        if (`$ns -is [System.Collections.IDictionary]) {
                            foreach (`$nuKey in @('poolNetworkUser', 'stashNetworkUser')) {
                                `$nu = if (`$ns.Contains(`$nuKey)) { "`$(`$ns[`$nuKey])".Trim() } else { '' }
                                if (`$nu) { [void]`$allowed.Add(`$nu) }
                            }
                        }
                        if (-not `$allowed.Contains([string]`$qUser)) {
                            `$vcStatus = 404; `$vcError = 'user not referenced by this host''s networkStorage config'
                        } else {
                            `$tm = Get-EffectiveUser -LogicalUser 'pool-auth-token'
                            if (-not `$tm.vaultKey -or -not (Test-VaultEntry -VaultKey `$tm.vaultKey)) {
                                `$vcStatus = 503; `$vcError = 'shared pool-auth-token not configured on this host'
                            } else {
                                `$vcToken = Get-Password -Username 'pool-auth-token'
                                if (-not (Test-ConfigSyncProof -Token `$vcToken -User `$qUser -Nonce `$qNonce -Proof `$qProof)) {
                                    `$vcStatus = 403; `$vcError = 'proof mismatch (wrong or stale shared token)'
                                } else {
                                    `$um = Get-EffectiveUser -LogicalUser `$qUser
                                    `$vcKey = if (`$um.vaultKey) { `$um.vaultKey } else { [string]`$qUser }
                                    if (-not (Test-VaultEntry -VaultKey `$vcKey)) {
                                        `$vcStatus = 404; `$vcError = 'no stored credential for that user on this host'
                                    } else {
                                        `$pw = Get-Password -Username `$qUser
                                        `$envelope = Protect-ConfigSyncCredential -Token `$vcToken -User `$qUser -ClientNonce `$qNonce -Password `$pw
                                        `$envelope['ok'] = `$true
                                        `$payload = `$envelope | ConvertTo-Json -Compress -Depth 3
                                    }
                                }
                            }
                        }
                    } catch {
                        `$vcStatus = 500
                        `$vcError = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                        Write-ServerErr "vault-credential failed: `$vcError"
                    }
                }
                if (`$vcError) {
                    `$res.StatusCode = `$vcStatus
                    `$errMsg = (`$vcError -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + `$errMsg + '"}')
                } else {
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                }
                `$res.ContentLength64 = `$bytes.Length
                `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: Control endpoints: Pause/Continue back-channel from UI
            # Two pause switches, each backed by a flag file, mirrored
            # into status.json so the next UI poll flips the banner:
            #   control.step-pause  — Invoke-Sequence checks at every
            #                         step boundary; stops after the
            #                         running step finishes.
            #   control.cycle-pause — Invoke-TestRunner checks at the
            #                         cycle boundary; stops after the
            #                         current cycle finishes cleanup.
            # Parent-side Write-StatusJson keeps both in sync by
            # re-reading the files on each write.
            if (`$path -eq 'control/step-pause' -or `$path -eq 'control/step-resume' -or
                `$path -eq 'control/cycle-pause' -or `$path -eq 'control/cycle-resume') {
                `$isCycle = (`$path -like 'control/cycle-*')
                `$desiredPaused = (`$path -like 'control/*-pause')
                `$targetFile = if (`$isCycle) { `$cyclePauseFile } else { `$stepPauseFile }
                `$fieldName  = if (`$isCycle) { 'cyclePaused' } else { 'stepPaused' }
                try {
                    if (`$desiredPaused) {
                        Set-Content -Path `$targetFile -Value (Get-Date -Format o) -ErrorAction SilentlyContinue
                    } else {
                        Remove-Item `$targetFile -Force -ErrorAction SilentlyContinue
                    }
                } catch { Write-Debug `$_ }
                try {
                    # Read-modify-write: must read fresh from disk every
                    # time (a concurrent runner-side write would otherwise
                    # be silently clobbered if we returned a cached parse).
                    # [File]::ReadAllText skips the Get-Content cmdlet-
                    # binding / encoding-sniff overhead.
                    `$doc = [System.IO.File]::ReadAllText(`$statusJsonFile) | ConvertFrom-Json -AsHashtable
                    `$doc[`$fieldName] = `$desiredPaused
                    `$tmp = "`$statusJsonFile.`$PID-`$([guid]::NewGuid().ToString('N')).tmp"
                    `$doc | ConvertTo-Json -Depth 20 | Set-Content -Path `$tmp -Encoding utf8
                    Move-Item -Path `$tmp -Destination `$statusJsonFile -Force
                } catch { Write-Debug `$_ }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$pausedJson = if (`$desiredPaused) { 'true' } else { 'false' }
                `$payload = '{"ok":true,"' + `$fieldName + '":' + `$pausedJson + '}'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/break-continue: Continue-from-break button
            # POST-only. Writes control.break-continue under runtimeDir;
            # the break action in Invoke-Sequence.psm1 polls for this
            # file inside its wait loop and on detection calls
            # Restore-VMDiskSnapshot (if break.id was set) + Start-VM,
            # removes the marker, and resumes the sequence.
            # Refuses the call when no break is active (no break-active.json
            # sidecar) so a stray click doesn't arm the flag for the
            # NEXT break -- which would silently auto-resume it on the
            # first poll tick.
            if (`$path -eq 'control/break-continue') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"POST required"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$breakActiveFile   = Join-Path `$runtimeDir 'break-active.json'
                `$breakContinueFile = Join-Path `$runtimeDir 'control.break-continue'
                if (-not (Test-Path -LiteralPath `$breakActiveFile)) {
                    `$res.StatusCode = 409
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"no break active"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                try {
                    Set-Content -Path `$breakContinueFile -Value (Get-Date -Format o) -ErrorAction Stop
                } catch {
                    `$res.StatusCode = 500
                    `$msg = '{"ok":false,"error":"could not write continue flag: ' + (`$_.Exception.Message -replace '"','\\"') + '"}'
                    `$body = [System.Text.Encoding]::UTF8.GetBytes(`$msg)
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/start-cycle: save-and-restart trigger from UI
            # POST-only. Atomically (under a process-wide lock file so
            # concurrent UI clicks don't double-spawn):
            #   1. clear control.cycle-pause and control.step-pause so a
            #      paused runner unblocks immediately
            #   2. touch control.cycle-restart so an in-delay-loop inner
            #      wakes early and exits to outer (see Invoke-TestInnerRunner.ps1)
            #   3. run Remove-TestVMFiles.ps1 -- this kills any in-progress
            #      VMs out from under a running cycle; the inner then errors
            #      out, outer respawns, and the saved test.config.yml mtime
            #      change is what wakes outer out of its failure-pause
            #   4. if no runner is currently running, spawn Invoke-TestRunner.ps1
            #      detached (same idiom Start-StatusService.ps1 uses to spawn
            #      this server -- Start-Process Hidden on Windows, bash nohup
            #      on Linux/macOS)
            # Save the test.config.yml separately via /control/test-config
            # before calling this (test.config.html does both back-to-back).
            if (`$path -eq 'control/start-cycle') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.StatusCode = 405
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"POST required"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                # File-existence lock. CreateNew is atomic at the OS layer;
                # if another endpoint instance is mid-flight the open
                # throws and we return 409. No mutex object so an
                # abandoned-handle scenario can't deadlock the next click;
                # worst case the holder crashes and leaves the lock file,
                # which is cleaned up on next start-cycle attempt (see the
                # stale-lock sweep below).
                `$lockFile = Join-Path `$runtimeDir 'control.start-cycle.lock'
                `$lockHandle = `$null
                # Stale-lock sweep: if the lock file is older than 5 minutes
                # the prior endpoint instance is gone (Remove-TestVMFiles +
                # spawn shouldn't take anywhere near that). Clean up so the
                # operator isn't permanently locked out.
                if (Test-Path -LiteralPath `$lockFile) {
                    try {
                        `$lockAge = (Get-Date) - (Get-Item -LiteralPath `$lockFile).LastWriteTime
                        if (`$lockAge.TotalSeconds -gt 300) {
                            Remove-Item -LiteralPath `$lockFile -Force -ErrorAction SilentlyContinue
                            Write-ServerErr "start-cycle: cleared stale lock (`$([int]`$lockAge.TotalSeconds)s old)"
                        }
                    } catch { Write-Debug `$_ }
                }
                try {
                    `$lockHandle = [System.IO.File]::Open(`$lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                } catch {
                    `$res.StatusCode = 409
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"another start-cycle request is in progress"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$action = 'restarted'
                `$errMsg = `$null
                try {
                    # 1. clear pause flags (start implies un-pause)
                    Remove-Item `$cyclePauseFile -Force -ErrorAction SilentlyContinue
                    Remove-Item `$stepPauseFile  -Force -ErrorAction SilentlyContinue
                    try {
                        # Same RMW reasoning as the pause-control handler:
                        # cannot cache the parse without risking a clobber.
                        `$doc = [System.IO.File]::ReadAllText(`$statusJsonFile) | ConvertFrom-Json -AsHashtable
                        `$doc['cyclePaused'] = `$false
                        `$doc['stepPaused']  = `$false
                        `$tmp = "`$statusJsonFile.`$PID-`$([guid]::NewGuid().ToString('N')).tmp"
                        `$doc | ConvertTo-Json -Depth 20 | Set-Content -Path `$tmp -Encoding utf8
                        Move-Item -Path `$tmp -Destination `$statusJsonFile -Force
                    } catch { Write-Debug `$_ }

                    # 2. signal "wake from inter-cycle delay" to a running inner
                    `$restartFlag = Join-Path `$runtimeDir 'control.cycle-restart'
                    Set-Content -Path `$restartFlag -Value (Get-Date -Format o) -ErrorAction SilentlyContinue

                    # 3. detect whether a runner is currently alive (same
                    #    logic as /control/runner-status: PID file + start
                    #    cross-check + cmdline regex fallback). Done BEFORE
                    #    Remove-TestVMFiles so the spawn decision is based
                    #    on pre-kill state.
                    `$runnerAlive    = `$false
                    `$runnerPidFile  = Join-Path `$runtimeDir 'runner.pid'
                    `$runnerStartFile = Join-Path `$runtimeDir 'runner.start'
                    if (Test-Path -LiteralPath `$runnerPidFile) {
                        try {
                            `$rawPid = (Get-Content -LiteralPath `$runnerPidFile -Raw -ErrorAction Stop).Trim()
                            if (`$rawPid -as [int]) {
                                `$pidVal = [int]`$rawPid
                                `$proc = Get-Process -Id `$pidVal -ErrorAction SilentlyContinue
                                if (`$proc) {
                                    if (Test-Path -LiteralPath `$runnerStartFile) {
                                        try {
                                            `$recorded   = (Get-Content -LiteralPath `$runnerStartFile -Raw -ErrorAction Stop).Trim()
                                            `$recordedDt = [DateTimeOffset]::Parse(`$recorded).UtcDateTime
                                            `$liveDt     = `$proc.StartTime.ToUniversalTime()
                                            if ([Math]::Abs((`$recordedDt - `$liveDt).TotalSeconds) -le 2) { `$runnerAlive = `$true }
                                        } catch { Write-Debug `$_ }
                                    }
                                    if (-not `$runnerAlive) {
                                        `$cmd = `$null
                                        if (`$IsWindows) {
                                            `$cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=`$pidVal" -ErrorAction SilentlyContinue).CommandLine
                                        } elseif (`$IsMacOS -or `$IsLinux) {
                                            `$cmd = & '/bin/ps' -ww -p `$pidVal -o args= 2>`$null
                                        }
                                        if (`$cmd -and `$cmd -match 'Invoke-Test(?:Inner)?Runner\.ps1') { `$runnerAlive = `$true }
                                    }
                                }
                            }
                        } catch { Write-Debug `$_ }
                    }

                    # 4. Remove-TestVMFiles synchronously. Captures both
                    #    streams; non-zero exit is surfaced in the response
                    #    so the operator can investigate, but does NOT
                    #    abort the spawn (hard-stop noise is accepted).
                    `$removeScript = Join-Path `$repoRoot 'test/Remove-TestVMFiles.ps1'
                    if (Test-Path -LiteralPath `$removeScript) {
                        try {
                            `$removeOut = & pwsh -NoProfile -ExecutionPolicy Bypass -WorkingDirectory `$repoRoot -File `$removeScript 2>&1 | Out-String
                            Write-ServerErr "start-cycle: Remove-TestVMFiles output:`n`$removeOut"
                        } catch {
                            Write-ServerErr "start-cycle: Remove-TestVMFiles threw: `$(`$_.Exception.Message)"
                        }
                    } else {
                        Write-ServerErr "start-cycle: Remove-TestVMFiles.ps1 not found at `$removeScript"
                    }

                    # 5. spawn outer runner if it wasn't already alive.
                    #    Mirrors the Start-StatusService.ps1 spawn idiom:
                    #    Start-Process Hidden on Windows, bash nohup on
                    #    Linux/macOS. Stdout/stderr redirected to runtime-dir
                    #    log files so the operator can debug a failed spawn.
                    if (-not `$runnerAlive) {
                        `$action = 'spawned'
                        `$runnerScript = Join-Path `$repoRoot 'test/Invoke-TestRunner.ps1'
                        if (-not (Test-Path -LiteralPath `$runnerScript)) {
                            throw "Invoke-TestRunner.ps1 not found at `$runnerScript"
                        }
                        `$spawnOut = Join-Path `$runtimeDir 'runner.spawned-from-web.out'
                        `$spawnErr = Join-Path `$runtimeDir 'runner.spawned-from-web.err'
                        if (`$IsWindows) {
                            # Quote `$runnerScript so Start-Process emits a
                            # correctly-quoted command line for paths that
                            # contain spaces (e.g. C:\Users\Yuruna Test\...).
                            `$runnerScriptQuoted = '"' + `$runnerScript + '"'
                            # -RedirectStandardInput against an empty file:
                            # see the spawn site at the bottom of
                            # Start-StatusService.ps1 for the full rationale.
                            # Same trap class -- without it the spawned
                            # runner inherits this status server's stdin
                            # handle, which on Windows pins conhost on
                            # parent-shell exit. Passing 'NUL' is rejected
                            # by Start-Process's path resolver, so we use
                            # a persistent empty sentinel file in the
                            # runtime dir instead.
                            `$stdinSink = Join-Path `$runtimeDir 'stdin.empty'
                            if (-not (Test-Path -LiteralPath `$stdinSink)) {
                                [System.IO.File]::WriteAllBytes(`$stdinSink, [byte[]]@())
                            }
                            Start-Process -FilePath "pwsh" ``
                                -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", `$runnerScriptQuoted ``
                                -WorkingDirectory `$repoRoot ``
                                -RedirectStandardInput  `$stdinSink ``
                                -RedirectStandardOutput `$spawnOut ``
                                -RedirectStandardError  `$spawnErr ``
                                -PassThru | Out-Null
                        } else {
                            # 'set -m' enables job control so the trailing & puts
                            # the runner in its OWN process group -- without it the
                            # runner inherits this status server's group and stays
                            # wired to its terminal job. nohup plus stdio redirected
                            # off the tty let it outlive the caller cleanly.
                            & bash -c "set -m; cd '`$repoRoot' && nohup pwsh -NoProfile -File '`$runnerScript' </dev/null > '`$spawnOut' 2> '`$spawnErr' &" | Out-Null
                        }
                        Write-ServerErr "start-cycle: spawned new runner from web endpoint"
                    }
                } catch {
                    `$errMsg = `$_.Exception.Message
                    Write-ServerErr "start-cycle failed: `$errMsg"
                } finally {
                    if (`$lockHandle) {
                        try { `$lockHandle.Close() } catch { Write-Debug `$_ }
                        Remove-Item -LiteralPath `$lockFile -Force -ErrorAction SilentlyContinue
                    }
                }
                if (`$errMsg) {
                    `$res.StatusCode = 500
                    `$escapedErr = (`$errMsg -replace '\\', '\\\\') -replace '"', '\"'
                    `$payload = '{"ok":false,"error":"' + `$escapedErr + '"}'
                } else {
                    `$payload = '{"ok":true,"action":"' + `$action + '"}'
                }
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /livecheck — cheap reachability probe for guests
            # Test-YurunaHost.ps1 (and fetch-and-execute's host probe) GET
            # this; success means "host server is reachable from this
            # guest, prefer it over GitHub." JSON body is {ok, service,
            # time} — `service` lets a misdirected probe (e.g. someone
            # else's HTTP server on the same port) be distinguished by
            # value, not just by 200/non-200.
            if (`$path -eq 'livecheck' -or `$path -eq 'livecheck/') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$payload = @{
                    ok      = `$true
                    service = 'yuruna-status-service'
                    time    = (Get-Date).ToString('o')
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                # HEAD: advertise Content-Length but send no body.
                # HTTP.sys RSTs the connection when user code writes
                # bytes for a HEAD response, which made wget --spider
                # probes from automation/fetch-and-execute.sh fail and
                # silently fall back to GitHub for every fetch.
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /diagnostics/<folder>/<filename> — guest-pushed diagnostic dump
            # Second-defence path for Test.Diagnostic. The host has just
            # injected a one-liner into the guest console that:
            #   1. wgets automation/Get-SystemDiagnostic.ps1 from us,
            #   2. runs it locally on the guest,
            #   3. POSTs the captured text to this endpoint.
            # We accept POST only and only into a folder that already
            # exists under logDir (the per-guest cycleGuestDataFolder
            # is the trust anchor: only the runner creates these, so
            # writing into one cannot be initiated by an attacker that
            # hasn't already caused the cycle to enter that guest's
            # loop). The filename has to match `*.system.diagnostic.*.txt`
            # so it lines up with Test.Diagnostic's Get-DiagnosticsFileName
            # output (yyyy-MM-dd.HH-mm.system.diagnostic.<Id>.txt). Body
            # cap is 5 MB; a real dump is ~30-60 kB, so anything larger
            # is an upload pathology, not a legit capture.
            if (`$path -like 'diagnostics/*') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"method not allowed; POST the dump body"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                # path: 'diagnostics/<folder>.../<filename>' -- at least
                # 2 segments after the prefix; the last is the filename
                # and everything before is the folder relative to logDir.
                # The current layout writes to <logDir>/<cycleBase>/<VMName>/
                # so the typical request has 3 segments. The older
                # <logDir>/<failure-folder>/ flat layout (2 segments)
                # is still accepted because the existence-on-disk check
                # below is what gates writes -- the runner is the only
                # producer of these folders, so anything that resolves
                # to an existing dir is by construction a runner-created
                # cycle artifact.
                `$rel  = `$path.Substring(12)
                `$segs = @(`$rel -split '/' | Where-Object { `$_ })
                if (`$segs.Count -lt 2 -or (`$segs | Where-Object { -not `$_ })) {
                    `$res.StatusCode = 400
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"expected /diagnostics/<folder>.../<filename>"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$diagFile   = `$segs[-1]
                `$folderSegs = `$segs[0..(`$segs.Count - 2)]
                # Relative folder path reported in the success payload and error log below.
                `$diagFolder = (`$folderSegs -join '/')
                # Path-traversal guard on every folder segment. Filename
                # is checked separately below. We don't pattern-match the
                # folder shape (the older *.failure-screens-* check is
                # obsolete -- cycleGuestDataFolders are just the VM name)
                # because the existence-on-disk requirement at the end
                # of this block is the actual security boundary.
                # Note: ``continue`` inside the loop would only iterate
                # over segments -- we set a flag and break, then short-
                # circuit out of the dispatch with ``continue`` against
                # the enclosing request loop.
                `$segReject = `$false
                foreach (`$seg in `$folderSegs) {
                    if (`$seg -match '[\\]' -or `$seg -match '\.\.') { `$segReject = `$true; break }
                }
                if (`$segReject) {
                    `$res.StatusCode = 400
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"folder segment contains traversal or backslash"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$diagFile -notlike '*.system.diagnostic.*.txt' -or `$diagFile -match '[\\/]' -or `$diagFile -match '\.\.') {
                    `$res.StatusCode = 400
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"filename must match *.system.diagnostic.<id>.txt"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$folderPath = `$logDir
                foreach (`$seg in `$folderSegs) { `$folderPath = Join-Path `$folderPath `$seg }
                if (-not (Test-Path -LiteralPath `$folderPath -PathType Container)) {
                    `$res.StatusCode = 404
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"failure folder not found; runner must have created it first"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                # Pin the resolved file under logDir so a folder name that
                # somehow normalized to a parent (won't happen given the
                # checks above, but layered defence) still can't escape.
                `$filePath = [System.IO.Path]::GetFullPath((Join-Path `$folderPath `$diagFile))
                `$logRootFull = [System.IO.Path]::GetFullPath(`$logDir)
                if (-not `$filePath.StartsWith(`$logRootFull)) {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"path escapes log root"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$req.ContentLength64 -gt 5MB) {
                    `$res.StatusCode = 413
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"payload too large (>5 MB)"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                # Stream the body straight to disk via a FileStream copy --
                # we don't need to decode/inspect, and avoiding the
                # StreamReader allocation keeps a 1 MB body off the GC
                # heap. Tmp + Move-Item preserves the "no partial file
                # visible to the dashboard" property the dispatcher already
                # depends on elsewhere.
                `$tmp = "`$filePath.tmp"
                `$bytesWritten = 0
                `$writeOk = `$false
                try {
                    `$out = [System.IO.File]::Create(`$tmp)
                    try {
                        `$buf = New-Object byte[] 8192
                        while (`$true) {
                            `$n = `$req.InputStream.Read(`$buf, 0, `$buf.Length)
                            if (`$n -le 0) { break }
                            `$out.Write(`$buf, 0, `$n)
                            `$bytesWritten += `$n
                            if (`$bytesWritten -gt 5MB) { throw 'streamed body exceeded 5 MB cap' }
                        }
                    } finally { `$out.Dispose() }
                    Move-Item -LiteralPath `$tmp -Destination `$filePath -Force
                    `$writeOk = `$true
                } catch {
                    `$res.StatusCode = 500
                    `$errMsg = (`$_.Exception.Message -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"write failed: ' + `$errMsg + '"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    Write-ServerErr "diagnostics write failed (`$diagFolder/`$diagFile): `$errMsg"
                } finally {
                    if (-not `$writeOk -and (Test-Path -LiteralPath `$tmp)) {
                        Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue
                    }
                }
                if (-not `$writeOk) { `$res.OutputStream.Close(); continue }
                `$payload = '{"ok":true,"bytes":' + `$bytesWritten + ',"path":"log/' + `$diagFolder + '/' + `$diagFile + '"}'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /yuruna-archive.tar.gz — committed-content tarball
            # Replaces ``git clone`` for guests in the dev iteration loop:
            # ``git archive --format=tar.gz HEAD`` streams a tarball of
            # the latest committed tree, no .git/, no working-tree
            # uncommitted noise. Sidesteps the deny-list (which forbids
            # .git/) since it does not expose the repo internals.
            if (`$path -eq 'yuruna-archive.tar.gz') {
                `$tmp       = [System.IO.Path]::GetTempFileName()
                `$originDir = `$null
                try {
                    # Inject a .yuruna-origin sidecar at the tarball root so
                    # guests (which have no .git/ after `git archive` extract)
                    # can still report the framework repo's origin URL in
                    # Get-SystemDiagnostic. --add-file places the file at
                    # archive root using its basename.
                    `$archiveArgs = @('-C', `$repoRoot, 'archive', '--format=tar.gz')
                    `$originUrl = & git -C `$repoRoot config --get remote.origin.url 2>`$null
                    if (`$LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(`$originUrl)) {
                        `$originDir  = New-Item -ItemType Directory -Path ([IO.Path]::Combine([IO.Path]::GetTempPath(), [Guid]::NewGuid().ToString('N'))) -Force
                        `$originFile = Join-Path `$originDir.FullName '.yuruna-origin'
                        [IO.File]::WriteAllText(`$originFile, (([string]`$originUrl).Trim()))
                        `$archiveArgs += ('--add-file=' + `$originFile)
                    }
                    `$archiveArgs += @('-o', `$tmp, 'HEAD')
                    & git @archiveArgs 2>`$null
                    if (`$LASTEXITCODE -ne 0 -or -not (Test-Path `$tmp)) {
                        `$res.StatusCode = 500
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('git archive failed')
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    `$bytes = [System.IO.File]::ReadAllBytes(`$tmp)
                    `$res.ContentType = 'application/gzip'
                    `$res.Headers.Add('Cache-Control', 'no-store')
                    `$res.ContentLength64 = `$bytes.Length
                    `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                    `$res.OutputStream.Close()
                } catch {
                    Write-ServerErr "yuruna-archive: `$(`$_.Exception.Message)"
                    try { `$ctx.Response.Abort() } catch { Write-Debug `$_ }
                } finally {
                    Remove-Item `$tmp -Force -ErrorAction SilentlyContinue
                    if (`$originDir) { Remove-Item -LiteralPath `$originDir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                }
                continue
            }

            # --- REGION: /yuruna-project-archive.tar.gz — project repo tarball
            # Symmetric counterpart to /yuruna-archive.tar.gz, but for the
            # project repo at <repoRoot>/project/. Update-ProjectClone
            # populates that folder each cycle by ``git clone``-ing the
            # configured repositories.projectUrl, so HEAD here is the
            # project's latest committed tree.
            #
            # Returns 404 when the project dir is missing or not a git
            # repo - that's the in-tree-stop-gap path (repositories.projectUrl
            # is empty in test.config.yml, no clone happened) and the guest
            # bootstrap interprets a 404 here as "fall back to git clone".
            if (`$path -eq 'yuruna-project-archive.tar.gz') {
                `$projectRoot = Join-Path `$repoRoot 'project'
                if (-not (Test-Path -LiteralPath (Join-Path `$projectRoot '.git'))) {
                    `$res.StatusCode = 404
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('project repo not present on host')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$tmp       = [System.IO.Path]::GetTempFileName()
                `$originDir = `$null
                try {
                    # Mirrors /yuruna-archive.tar.gz: inject a .yuruna-origin
                    # sidecar so guests can recover the project repo's
                    # origin URL even though `git archive` strips .git/.
                    `$archiveArgs = @('-C', `$projectRoot, 'archive', '--format=tar.gz')
                    `$originUrl = & git -C `$projectRoot config --get remote.origin.url 2>`$null
                    if (`$LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(`$originUrl)) {
                        `$originDir  = New-Item -ItemType Directory -Path ([IO.Path]::Combine([IO.Path]::GetTempPath(), [Guid]::NewGuid().ToString('N'))) -Force
                        `$originFile = Join-Path `$originDir.FullName '.yuruna-origin'
                        [IO.File]::WriteAllText(`$originFile, (([string]`$originUrl).Trim()))
                        `$archiveArgs += ('--add-file=' + `$originFile)
                    }
                    `$archiveArgs += @('-o', `$tmp, 'HEAD')
                    & git @archiveArgs 2>`$null
                    if (`$LASTEXITCODE -ne 0 -or -not (Test-Path `$tmp)) {
                        `$res.StatusCode = 500
                        `$body = [System.Text.Encoding]::UTF8.GetBytes('git archive failed')
                        `$res.OutputStream.Write(`$body, 0, `$body.Length)
                        `$res.OutputStream.Close()
                        continue
                    }
                    `$bytes = [System.IO.File]::ReadAllBytes(`$tmp)
                    `$res.ContentType = 'application/gzip'
                    `$res.Headers.Add('Cache-Control', 'no-store')
                    `$res.ContentLength64 = `$bytes.Length
                    `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                    `$res.OutputStream.Close()
                } catch {
                    Write-ServerErr "yuruna-project-archive: `$(`$_.Exception.Message)"
                    try { `$ctx.Response.Abort() } catch { Write-Debug `$_ }
                } finally {
                    Remove-Item `$tmp -Force -ErrorAction SilentlyContinue
                    if (`$originDir) { Remove-Item -LiteralPath `$originDir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                }
                continue
            }

            # --- REGION: /log-upload/<rel>: write a diagnostic file under `$logDir
            # Failed-install diagnostic sink. Subiquity's error-commands
            # block runs INSIDE the installer environment (not the half-
            # built target) when the install aborts, and POSTs
            # /var/log/installer/* here before the VM dies. Without this
            # endpoint the only failure evidence is the screen OCR; the
            # underlying apt stderr / curtin trace is lost when the
            # installer drops to shell. Mirrors the static /log/ GET
            # route so an uploaded file appears in the dashboard's
            # cycle-log listing as soon as it lands.
            #
            # Scoped narrowly to keep the write surface tight:
            #   * Method:    PUT or POST only.
            #   * Path:      log-upload/<rel> with no '..' segments.
            #   * Extension: .log .txt .json .err .crash (matches what
            #                /var/log/installer/* actually produces;
            #                rejects e.g. .ps1 / .exe upload attempts).
            #   * Body cap:  4 MB (a typical curtin-install.log tail is
            #                ~200 KB; full file ~1-2 MB).
            # Path is normalized + range-checked against `$logDir so
            # nothing escapes the log mount.
            if (`$path -like 'log-upload/*') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'PUT' -and `$req.HttpMethod -ne 'POST') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'PUT, POST')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"PUT or POST required"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$uploadRel = `$path.Substring(11) -replace '\\','/'
                `$uploadDeny = `$false
                if ([string]::IsNullOrWhiteSpace(`$uploadRel))             { `$uploadDeny = `$true }
                elseif (`$uploadRel -match '(^|/)\.\.(/|`$)')              { `$uploadDeny = `$true }
                elseif (`$uploadRel -match '^/')                           { `$uploadDeny = `$true }
                elseif (-not (`$uploadRel -match '\.(log|txt|json|err|crash)`$')) { `$uploadDeny = `$true }
                if (`$uploadDeny) {
                    `$res.StatusCode = 400
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"invalid upload path (must end in .log/.txt/.json/.err/.crash, no traversal)"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$req.ContentLength64 -gt 4MB) {
                    `$res.StatusCode = 413
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"payload too large (>4 MB)"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$uploadTarget = Join-Path `$logDir `$uploadRel
                `$uploadFull   = [System.IO.Path]::GetFullPath(`$uploadTarget)
                `$logDirFull   = [System.IO.Path]::GetFullPath(`$logDir)
                if (-not `$uploadFull.StartsWith(`$logDirFull)) {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"path escapes log dir"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$uploadParent = Split-Path -Parent `$uploadFull
                `$writeOk = `$false
                `$writeErr = `$null
                try {
                    if (-not (Test-Path -LiteralPath `$uploadParent)) {
                        `$null = New-Item -ItemType Directory -Force -Path `$uploadParent -ErrorAction Stop
                    }
                    `$out = [System.IO.File]::Open(`$uploadFull, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                    try {
                        `$buf = New-Object byte[] 65536
                        `$total = 0L
                        while (`$true) {
                            `$n = `$req.InputStream.Read(`$buf, 0, `$buf.Length)
                            if (`$n -le 0) { break }
                            `$total += `$n
                            if (`$total -gt 4MB) { throw "payload exceeded 4 MB mid-stream" }
                            `$out.Write(`$buf, 0, `$n)
                        }
                    } finally { `$out.Dispose() }
                    `$writeOk = `$true
                } catch {
                    `$writeErr = `$_.Exception.Message
                    Write-ServerErr "log-upload write failed for `$uploadRel : `$writeErr"
                }
                if (-not `$writeOk) {
                    `$res.StatusCode = 500
                    `$errEsc = (`$writeErr -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' ')
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"write failed: ' + `$errEsc + '"}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.StatusCode = 201
                `$relEsc = (`$uploadRel -replace '\\','\\' -replace '"','\"')
                `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"path":"' + `$relEsc + '"}')
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # Dispatch by URL prefix:
            #   yuruna-repo/<rel> -> `$repoRoot (working tree, with deny-list)
            #   runtime/<name>    -> `$runtimeDir (pids, status.json, control
            #                                     flags, ipaddresses.txt,
            #                                     caching-proxy.txt,
            #                                     current-action.json, server.err,
            #                                     yuruna-caching-proxy.yml,
            #                                     host.uuid)
            #   log/<name>        -> `$logDir    (HTML transcripts, OCR /
            #                                     screenshot debug, failure
            #                                     captures)
            #   <anything>        -> `$statusDir (index.html, template, static
            #                                     assets, plus perf/, extension/,
            #                                     captures/, ssh/ subdirs)
            # Each branch pins the resolved file under its mount root
            # via a StartsWith check -- traversal like
            # runtime/../../../etc/passwd can't escape.
            #
            # A unified deny-list (`$denyLikeStatus) is then applied to
            # every served path before the file is written so secrets
            # under status/ (vault.yml, transports.yml, events.log, the
            # SSH private key, the caching-proxy state file) are blocked
            # regardless of which URL route reached them.
            if (`$path -like 'yuruna-repo/*') {
                `$rel  = `$path.Substring(12)
                `$root = `$repoRoot
                # Deny-list: secrets, vault state, the .git directory.
                # Pattern-based so future credential / event-log files
                # in the same families are auto-protected.
                # The yuruna-project sequence files live elsewhere; this
                # only governs what ships out of the framework's repo.
                `$relNorm = `$rel -replace '\\','/'
                `$denyExact = @(
                    'test/test.config.yml',
                    '.git'
                )
                `$denyLike = @(
                    '*.pfx',
                    '.git/*',
                    '*/vault.yml',
                    '*/vault.lock',
                    '*/transports.yml',
                    'test/status/extension/*',
                    'test/status/ssh/*',
                    '*/yuruna-caching-proxy.yml',
                    'test/status/runtime/yuruna-caching-proxy.yml',
                    '*.events.log',
                    '*-password.txt'
                )
                `$denied = (`$denyExact -contains `$relNorm)
                if (-not `$denied) {
                    foreach (`$pat in `$denyLike) {
                        if (`$relNorm -like `$pat) { `$denied = `$true; break }
                    }
                }
                if (`$denied) {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden (deny-list)')
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
            } elseif (`$path -like 'runtime/*') {
                `$rel  = `$path.Substring(8)
                `$root = `$runtimeDir
            } elseif (`$path -like 'log/*') {
                `$rel  = `$path.Substring(4)
                `$root = `$logDir
            } else {
                `$rel  = `$path
                `$root = `$statusDir
            }
            # Unified deny-list across non-yuruna-repo dispatches. The
            # /runtime/ route serves runtime/yuruna-caching-proxy.yml
            # (plaintext yuruna user password); the catch-all serves
            # status/extension/ (vault.yml, vault.lock, transports.yml,
            # events.log) and status/ssh/ (private SSH key). Block all
            # of those uniformly so URL probing never returns secrets.
            if (`$path -notlike 'yuruna-repo/*') {
                `$relNorm = `$rel -replace '\\','/'
                `$denyLikeStatus = @(
                    '*/vault.yml',     'vault.yml',
                    '*/vault.lock',    'vault.lock',
                    '*/transports.yml','transports.yml',
                    '*/events.log',    'events.log',
                    'extension/*',
                    'ssh/yuruna_ed25519',
                    'ssh/*_ed25519',
                    '*/yuruna-caching-proxy.yml',
                    'yuruna-caching-proxy.yml',
                    '*-password.txt'
                )
                `$denied = `$false
                foreach (`$pat in `$denyLikeStatus) {
                    if (`$relNorm -like `$pat) { `$denied = `$true; break }
                }
                if (`$denied) {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden (deny-list)')
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
            }
            `$file = Join-Path `$root `$rel
            `$file = [System.IO.Path]::GetFullPath(`$file)
            `$rootFull = [System.IO.Path]::GetFullPath(`$root)
            if (-not `$file.StartsWith(`$rootFull)) {
                `$res.StatusCode = 403
                `$body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden')
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }
            # --- REGION: Directory listing
            # When the resolved path is a directory, serve an HTML index
            # of its contents with relative links. Used by the failure-
            # screens folder under /log/<id>.<ts>.failure-screens-<vm>/
            # whose <a href="…/"> in the HTML transcript otherwise 404'd.
            # Skipped for /yuruna-repo/* so a working-tree listing never
            # exposes paths beyond the existing per-file deny-list.
            if (Test-Path `$file -PathType Container) {
                if (`$path -like 'yuruna-repo/*' -or `$path -eq 'yuruna-repo' -or `$path -eq 'yuruna-repo/') {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden (directory listing disabled)')
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$origLocal = `$req.Url.LocalPath
                if (-not `$origLocal.EndsWith('/')) {
                    # Without a trailing slash the browser resolves the
                    # listing's relative <a href> one segment too high,
                    # so a click on raw_001.png would request
                    # /log/raw_001.png instead of /log/<dir>/raw_001.png.
                    `$res.StatusCode = 301
                    `$res.Headers.Add('Location', `$origLocal + '/')
                    `$res.OutputStream.Close()
                    continue
                }
                `$entries = @(Get-ChildItem -LiteralPath `$file -Force -ErrorAction SilentlyContinue |
                    Sort-Object @{Expression = { -not `$_.PSIsContainer }}, Name)
                `$sb = [System.Text.StringBuilder]::new()
                `$titleEnc = [System.Net.WebUtility]::HtmlEncode(`$origLocal)
                # Single-quoted concat avoids double-quote escaping
                # noise both at template time (`@"..."@` collapses
                # backtick-quote to bare quote, which would corrupt
                # the inner attribute quotes) and at deployed-parse
                # time. `$titleEnc` is the only dynamic part, so a
                # plain `+` keeps the rest literal.
                [void]`$sb.AppendLine('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><title>Index of ' + `$titleEnc + '</title><link rel="stylesheet" href="/yuruna.common.css"><style>body{margin:1.5em}h1{font-size:1.1em}table{border-collapse:collapse}td,th{padding:0.2em 1em;border-bottom:1px solid var(--border);font-family:var(--font-mono);text-align:left}th{background:var(--bg-hover)}</style></head><body>')
                [void]`$sb.AppendLine("<h1>Index of `$titleEnc</h1>")
                [void]`$sb.AppendLine('<table><thead><tr><th>Name</th><th>Size</th><th>Modified (UTC)</th></tr></thead><tbody>')
                if (`$origLocal -ne '/') {
                    [void]`$sb.AppendLine('<tr><td><a href="../">../</a></td><td></td><td></td></tr>')
                }
                foreach (`$e in `$entries) {
                    `$nameEnc = [System.Net.WebUtility]::HtmlEncode(`$e.Name)
                    `$hrefEnc = [Uri]::EscapeDataString(`$e.Name)
                    `$mtime   = `$e.LastWriteTimeUtc.ToString('o')
                    if (`$e.PSIsContainer) {
                        [void]`$sb.Append('<tr><td><a href="').Append(`$hrefEnc).Append('/">').Append(`$nameEnc).Append('/</a></td><td></td><td>').Append(`$mtime).AppendLine('</td></tr>')
                    } else {
                        [void]`$sb.Append('<tr><td><a href="').Append(`$hrefEnc).Append('">').Append(`$nameEnc).Append('</a></td><td>').Append(`$e.Length).Append('</td><td>').Append(`$mtime).AppendLine('</td></tr>')
                    }
                }
                [void]`$sb.AppendLine('</tbody></table></body></html>')
                `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$sb.ToString())
                `$res.ContentType = 'text/html; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                `$res.ContentLength64 = `$bytes.Length
                `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                `$res.OutputStream.Close()
                continue
            }
            if (Test-Path `$file -PathType Leaf) {
                `$ext = [System.IO.Path]::GetExtension(`$file)
                `$res.ContentType = switch (`$ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.txt'  { 'text/plain; charset=utf-8' }
                    '.png'  { 'image/png' }
                    '.sh'   { 'text/x-shellscript; charset=utf-8' }
                    '.ps1'  { 'text/plain; charset=utf-8' }
                    '.psm1' { 'text/plain; charset=utf-8' }
                    '.yml'  { 'text/yaml; charset=utf-8' }
                    '.yaml' { 'text/yaml; charset=utf-8' }
                    '.md'   { 'text/markdown; charset=utf-8' }
                    default { 'application/octet-stream' }
                }
                # Cache policy by file type. The two top-level dashboards
                # (index.html, test.config.html) carry a 60-second freshness
                # window with must-revalidate so a browser left open re-
                # fetches on the next navigation/poll instead of serving a
                # stale DOM that older 'no-store' headers paradoxically
                # leaked through some clients. Last-Modified rides along so
                # the revalidation can return 304 (cheap) when nothing
                # changed. Everything else mutates per cycle (.json) or is
                # repo content served for guests (.sh, .ps1, .psm1, .yml,
                # .yaml, .md) where a host edit + Start-StatusService
                # restart must be visible immediately -- those keep
                # no-store. .txt / .css / .js straddle: they're rare on
                # this server and we treat them like the dynamic bucket
                # to be safe.
                if (`$ext -eq '.html') {
                    `$res.Headers.Add('Cache-Control', 'public, max-age=60, must-revalidate')
                    `$res.Headers.Add('Last-Modified', ([System.IO.File]::GetLastWriteTimeUtc(`$file).ToString('R')))
                } elseif (`$ext -in '.json','.txt','.css','.js','.sh','.ps1','.psm1','.yml','.yaml','.md') {
                    `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                    `$res.Headers.Add('Pragma', 'no-cache')
                    `$res.Headers.Add('Expires', '0')
                }
                `$fileInfo = [System.IO.FileInfo]::new(`$file)
                if (`$fileInfo.Length -gt 50MB) {
                    `$res.StatusCode = 413
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('File too large')
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$bytes = [System.IO.File]::ReadAllBytes(`$file)
                `$res.ContentLength64 = `$bytes.Length
                `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
            } else {
                `$res.StatusCode = 404
                `$body = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                # /yuruna-repo/* 404s are operationally distinct from
                # generic dashboard 404s: they signal the working-tree
                # rename race (memory note feedback_status_server_
                # working_tree_rename_race.md) where a guest's mid-cycle
                # fetch-and-execute resolves to a path the host has just
                # renamed/deleted. Log the requested path + resolved file
                # so the operator can correlate a wget exit 8 in the
                # guest transcript with the file that vanished here.
                if (`$path -like 'yuruna-repo/*') {
                    Write-ServerErr "yuruna-repo 404: path=`$path resolved=`$file"
                }
            }
            `$res.OutputStream.Close()
        } catch {
            try { `$ctx.Response.Abort() } catch { Write-Debug `$_ }
        }
      } catch {
        # Log unhandled iteration-level failures (EndGetContext throws,
        # listener kicked out by http.sys) and keep serving. Without
        # this the server died silently on the first transient blip.
        Write-ServerErr "iteration error: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
        Start-Sleep -Milliseconds 200
      }
    }
} catch {
    Write-ServerErr "fatal: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
    throw
} finally { `$listener.Stop() }
"@

# Write the server script to a file and launch with -File rather than
# base64-encoding it onto the command line. The server script grew past
# ~23 KB of source, which becomes ~61 KB when base64(UTF-16LE) encoded --
# that plus the pwsh.exe path (on Windows Store installs, pwsh resolves
# to a 100+ char Microsoft.PowerShell_*_8wekyb3d8bbwe\pwsh.exe path)
# pushes the command line past the Windows CreateProcess 32,767-char
# limit. The failure mode is a Start-Process error reading
# "The filename or extension is too long" which is obscure and easy to
# misread as a path problem. -File sidesteps the size limit entirely:
# pwsh reads the script from disk instead of its command line.
# Reap the legacy generated server script (.status-server.ps1, distinct
# from today's .status-service.ps1) and its stdout log so an upgrade does not
# leave a stale, misleading copy under the runtime dir that an inspector could
# mistake for the live server. Runs before the current script is written below.
Remove-Item (Join-Path $RuntimeDir '.status-server.ps1') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $RuntimeDir 'server.out') -Force -ErrorAction SilentlyContinue

$serverScriptFile = Join-Path $RuntimeDir ".status-service.ps1"
Set-Content -Path $serverScriptFile -Value $serverScript -Encoding UTF8BOM

if ($IsWindows) {
    # Explicit stdio redirection on Windows is REQUIRED for outer-runner
    # liveness. Without -RedirectStandardOutput / -RedirectStandardError,
    # this grandchild inherits the parent's console handles. The chain
    # is: Invoke-TestRunner.ps1 spawns modules/Invoke-TestInnerRunner.ps1 with
    # Start-Process -NoNewWindow (shared console); the inner here spawns
    # the long-running status server which without explicit redirection
    # also inherits those shared handles. When the inner cycle ends and
    # the outer's WaitForExit() returns, the grandchild still holds the
    # console handles open — which on Windows can keep the outer's
    # Start-Process -Wait pinned past the inner's actual exit, producing
    # the symptom "[outer cycle N] outer runner back in control" never
    # firing on outer.log even though the inner clearly emitted its
    # final cycleDelaySeconds-wait-complete line. Redirecting to files
    # gives the grandchild dedicated handles and breaks the chain.
    $serverOut = Join-Path $RuntimeDir "server.out"
    $serverErrFile = Join-Path $RuntimeDir "server.err"
    # Wrap $serverScriptFile in literal double quotes before handing it to
    # -ArgumentList. Start-Process joins the array elements with spaces
    # WITHOUT quoting, so a path like "C:\Users\Yuruna Test\..." gets
    # re-split by CreateProcess and the child pwsh sees -File C:\Users\Yuruna
    # and reports: The argument 'C:\Users\Yuruna' is not recognized as the
    # name of a script file.
    $serverScriptQuoted = '"' + $serverScriptFile + '"'
    # -RedirectStandardInput against a real empty file is non-optional on
    # Windows: without an explicit stdin redirect, the detached child
    # inherits the parent console's stdin handle and conhost cannot tear
    # down when the parent pwsh exits, leaving the operator's PowerShell
    # window in a multi-second to indefinite close-pending state. Passing
    # 'NUL' / '\\.\NUL' does NOT work because Start-Process runs the value
    # through Resolve-Path, which prepends the current directory and then
    # the underlying FileStream open fails on the bogus cwd\NUL path. The
    # macOS branch below achieves the same effect via '</dev/null' in the
    # bash invocation -- bash's redirection accepts the device name
    # directly, so no sentinel file is needed there.
    $stdinSink = Join-Path $RuntimeDir 'stdin.empty'
    if (-not (Test-Path -LiteralPath $stdinSink)) {
        [System.IO.File]::WriteAllBytes($stdinSink, [byte[]]@())
    }
    $proc = Start-Process -FilePath "pwsh" `
        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $serverScriptQuoted `
        -RedirectStandardInput  $stdinSink `
        -RedirectStandardOutput $serverOut `
        -RedirectStandardError  $serverErrFile `
        -PassThru
    Set-Content -Path $PidFile -Value $proc.Id
} else {
    # On macOS/Linux, detach the status server from the test-runner shell's
    # terminal job. `bash -c` runs a NON-interactive shell, so job control is
    # off and a bare `&` leaves the backgrounded process in the caller's
    # process group: exiting that shell then lingers because its terminal job
    # still has a live member. `set -m` turns job control on for this shell,
    # so `&` places the server in its OWN process group (bash setpgid's it).
    # `nohup` ignores SIGHUP and stdin/stdout/stderr are redirected off the
    # tty, so the server cleanly outlives the caller. (macOS has no `setsid`,
    # so a new session is not available here -- a new process group plus
    # nohup is what decouples it from the caller's exit.)
    $stdErr = Join-Path $RuntimeDir "server.err"
    & bash -c "set -m; nohup pwsh -NoProfile -File '$serverScriptFile' </dev/null >/dev/null 2>'$stdErr' & echo `$!" | Set-Variable -Name bgPid
    Set-Content -Path $PidFile -Value $bgPid
}

# --- REGION: Verify server started
$serverReady = Wait-WithProgress -Activity "Status server: waiting for http://localhost:$Port/" `
    -TotalSeconds $script:StatusServiceReadyTimeoutSeconds -PollSeconds 1 -Test {
        try {
            $null = Invoke-WebRequest -Uri "http://localhost:$Port/status/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
            return $true
        } catch { return $false }
    }
if (-not $serverReady) {
    Write-Warning "Status server process started but port $Port is not responding after $script:StatusServiceReadyTimeoutSeconds seconds."
    Write-Warning "Check the server error log: $(Join-Path $RuntimeDir 'server.err')"
}

# Persist the framework HEAD SHA the new server was launched against so a
# subsequent Start-StatusService invocation (the per-cycle call from
# Invoke-TestInnerRunner.ps1) can short-circuit the kill+relaunch when the
# code the running server already loaded is still current. Written AFTER
# the readiness probe so a server that never came up does not advertise
# itself as "already running on SHA X" -- the missing SHA file forces the
# next call to restart.
try {
    $launchSha = (& git -C $RepoRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($launchSha) {
        [System.IO.File]::WriteAllText($ShaFile, $launchSha, [System.Text.UTF8Encoding]::new($false))
    } elseif (Test-Path -LiteralPath $ShaFile) {
        Remove-Item -LiteralPath $ShaFile -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Verbose "Could not persist server.sha: $($_.Exception.Message)" }

# --- REGION: Display connection info
$machineName = (hostname).Trim()
$ip = try {
    ([System.Net.Dns]::GetHostAddresses($machineName) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        Select-Object -First 1).IPAddressToString
} catch { $null }

Write-Output ""
$serverPid = (Get-Content $PidFile).Trim()
Write-Output "Status server started (PID $serverPid, port $Port)."
Write-Output "  Local:  http://localhost:$Port/status/"
if ($ip) {
    Write-Output "  Remote: http://${ip}:$Port/status/"
}
Write-Output "  Host:   http://${machineName}:$Port/status/"
Write-Output ""

# --- REGION: LAN reachability pre-check (Windows only)
# The server binds to http://*:$Port so the socket is on every interface,
# but on a fresh Windows 11 install the Defender Firewall drops inbound
# TCP on non-loopback interfaces unless an Allow rule was created. The
# local probe above only hit http://localhost which never exercises the
# firewall -- so the Remote: URL above could look valid and still time
# out from a LAN browser. Peek at the firewall rules Enable-TestAutomation
# creates; if the Allow rule is missing or disabled, warn loudly and
# print the remediation command before the user notices the silence.
# Get-NetFirewallRule is a read operation and does not require admin.
if ($IsWindows -and $ip) {
    try {
        $ruleName = "Yuruna: Allow inbound TCP :$Port (Status server)"
        $statusRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        $remoteReachable = $false
        if ($statusRule -and $statusRule.Enabled -eq 'True') {
            $portFilter = $statusRule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if ($portFilter -and $portFilter.Protocol -eq 'TCP' -and $portFilter.LocalPort -eq "$Port") {
                $remoteReachable = $true
            }
        }
        if (-not $remoteReachable) {
            # Distinguish "never configured" from "wrong port". Both paths
            # recommend re-running Enable-TestAutomation.ps1 because that
            # script is the single owner of these firewall rules.
            if (-not $statusRule) {
                Write-Warning "LAN reachability: no Windows Firewall rule found for inbound TCP :$Port."
            } elseif ($statusRule.Enabled -ne 'True') {
                Write-Warning "LAN reachability: firewall rule '$ruleName' exists but is DISABLED."
            } else {
                Write-Warning "LAN reachability: firewall rule '$ruleName' does not match TCP :$Port (test.config.yml port may have changed)."
            }
            Write-Warning "  http://localhost:$Port/status/ will work, but LAN clients hitting"
            Write-Warning "  http://${ip}:$Port/status/ will time out."
            Write-Warning "  To fix, open a new elevated pwsh and run:"
            Write-Warning "    cd $(Split-Path -Parent $TestRoot)"
            Write-Warning "    pwsh host\windows.hyper-v\Enable-TestAutomation.ps1"
        }
    } catch {
        Write-Verbose "Firewall-rule reachability check skipped: $($_.Exception.Message)"
    }
}

Write-Output "Stop with: .\Stop-StatusService.ps1"
