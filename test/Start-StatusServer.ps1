<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456740
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
    Starts the status HTTP server as an independent background process.

.DESCRIPTION
    Launches a detached pwsh process that serves the test/status/ directory
    over HTTP. The server keeps running even if the caller exits.
    A PID file ($env:YURUNA_TRACK_DIR/server.pid) is written so
    Stop-StatusServer.ps1 can shut it down later.

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
$TestRoot   = $PSScriptRoot
$RepoRoot   = Split-Path -Parent $TestRoot
$StatusDir  = Join-Path $TestRoot "status"
$ModulesDir = Join-Path $TestRoot "modules"

# $env:YURUNA_TRACK_DIR (runtime state) + $env:YURUNA_LOG_DIR (transcripts/
# debug artifacts). Default to status/ subdirs so the HTTP server serves
# them at /track/* and /log/*.
Import-Module (Join-Path $ModulesDir "Test.TrackDir.psm1")    -Force
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1")      -Force
Import-Module (Join-Path $ModulesDir "Test.VM.common.psm1")   -Force -DisableNameChecking
Import-Module (Join-Path $ModulesDir "Test.CachingProxy.psm1") -Force -DisableNameChecking
$null = Initialize-YurunaTrackDir
$null = Initialize-YurunaLogDir
$TrackDir = $env:YURUNA_TRACK_DIR
$LogDir   = $env:YURUNA_LOG_DIR

$PidFile = Join-Path $TrackDir "server.pid"

# --- Read port from config if not provided ---
if ($Port -eq 0) {
    $configPath = Join-Path $TestRoot "test.config.yml"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered
            if ($config.statusServer.port) { $Port = [int]$config.statusServer.port }
        } catch { Write-Warning "Could not read port from config: $_" }
    }
    if ($Port -eq 0) { $Port = 8080 }
}

# --- Stop existing server if -Restart was requested ---
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

# --- Check for an existing server ---
if (Test-Path $PidFile) {
    $oldPid = (Get-Content $PidFile).Trim()
    $serverAlive = $false
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        # Verify PID is a pwsh process (not a recycled PID)
        if ($proc -and $proc.ProcessName -match 'pwsh|PowerShell') {
            # Confirm port responds
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
        Write-Output "Status server is already running (PID $oldPid, port $Port)."
        Write-Output "Stop with: .\Stop-StatusServer.ps1"
        exit 0
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# --- Resolve port conflicts from untracked orphan detached servers ---
# The pid-file checks above know only about the server we last launched.
# A prior detached pwsh can still hold the HttpListener on :$Port if an
# older Start-StatusServer.ps1 survived a terminal close, or a failed
# launch overwrote $PidFile with a stillborn PID. New launches then die:
#   Failed to listen on prefix 'http://*:$Port/' because it conflicts
#   with an existing registration on the machine.
# The detached child logs that to $TrackDir/server.err and exits, so the
# outer script appears to start cleanly — nothing is serving, and any
# pre-refactor orphan keeps writing control files to the wrong place
# ($StatusDir vs. $TrackDir), silently breaking Pause/Cycle buttons.
#
# Probe with a throwaway HttpListener. If it succeeds, the detached
# launch will too. If not, resolve the real owner via OS tools and stop
# it — but ONLY if it's a pwsh process plausibly ours. Unknown owners
# (dev server, another tool) get a clear error and we bail.
function Get-PortListenerPid {
    param(
        [int]$Port,
        # Caller passes [ref]$diag to collect a human-readable description of
        # what we tried when no PID is resolved, so the "unavailable or empty"
        # warning can point the operator at the real cause (missing lsof, an
        # access-restricted owner, a non-LISTEN holder, etc.).
        [ref]$Diagnostic
    )

    if ($PSVersionTable.Platform -eq 'Unix') {
        # lsof is standard on macOS and most Linux.
        if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) {
            if ($Diagnostic) { $Diagnostic.Value = 'lsof not found in PATH' }
            return @()
        }

        # Primary: LISTEN-only, PID-only output. Capture stderr so that a
        # permission failure or an lsof-internal error is visible rather than
        # silently collapsed into "empty".
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $listenOut = & lsof -nP -iTCP:$Port -sTCP:LISTEN -Fp 2>$errFile
        } finally {
            $lsofStderr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) -as [string]
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
        $listenPids = @($listenOut | Where-Object { $_ -like 'p*' } | ForEach-Object { [int]$_.Substring(1) } | Select-Object -Unique)
        if ($listenPids.Count) { return $listenPids }

        # Fallback: any TCP state on this port. macOS lsof without sudo can
        # miss listeners owned by other users, and a half-closed socket that
        # still holds :$Port shows up under states other than LISTEN.
        $anyOut  = & lsof -nP -iTCP:$Port -Fp 2>$null
        $anyPids = @($anyOut | Where-Object { $_ -like 'p*' } | ForEach-Object { [int]$_.Substring(1) } | Select-Object -Unique)
        if ($anyPids.Count) {
            if ($Diagnostic) {
                $Diagnostic.Value = "lsof -sTCP:LISTEN returned no pids, but lsof (any state) found pid(s) $($anyPids -join ','); treating as holder"
            }
            return $anyPids
        }

        if ($Diagnostic) {
            $trimErr = if ($lsofStderr) { $lsofStderr.Trim() } else { '' }
            $parts   = @("lsof -nP -iTCP:$Port -sTCP:LISTEN -> empty", "lsof -nP -iTCP:$Port (any state) -> empty")
            if ($trimErr) { $parts += "lsof stderr: $trimErr" }
            $parts += "holder may be owned by another user; retry with: sudo lsof -nP -iTCP:$Port"
            $Diagnostic.Value = $parts -join '; '
        }
        return @()
    }

    # Windows: HTTP.sys hides the real owner from Get-NetTCPConnection
    # (OwningProcess reports 4, the System kernel account), so netsh is
    # the only reliable source for url-group → PID mapping. Output is
    # grouped per "Request queue name:" block; within a block,
    # `Processes: ID: <pid>` lists user-mode PIDs and `Registered URLs:`
    # lists URL prefixes. Flush a block's PIDs to the result set when
    # its URL list contains :$Port. The regex matches both
    # "HTTP://*:8080/" and the rarer "HTTP://127.0.0.1:8080:127.0.0.1/"
    # host-binding form.
    $raw = @(netsh http show servicestate 2>$null)
    if (-not $raw) {
        if ($Diagnostic) { $Diagnostic.Value = 'netsh http show servicestate returned no output' }
        return @()
    }

    $pids           = [System.Collections.Generic.HashSet[int]]::new()
    $blockPids      = [System.Collections.Generic.List[int]]::new()
    $blockPortMatch = $false
    foreach ($line in $raw) {
        if ($line -match '^\s*Request queue name:') {
            if ($blockPortMatch) { foreach ($p in $blockPids) { [void]$pids.Add($p) } }
            $blockPids.Clear(); $blockPortMatch = $false
        } elseif ($line -match '^\s*ID:\s*(\d+)\b') {
            [void]$blockPids.Add([int]$Matches[1])
        } elseif ($line -match "^\s*HTTPS?://[^\s]*:${Port}(?:[:/]|$)") {
            $blockPortMatch = $true
        }
    }
    if ($blockPortMatch) { foreach ($p in $blockPids) { [void]$pids.Add($p) } }
    if ($pids.Count -eq 0 -and $Diagnostic) {
        $Diagnostic.Value = "netsh http show servicestate: no url-group block registered :$Port"
    }
    return @($pids)
}

function Resolve-PortOrphan {
    param([int]$Port, [string]$PidFile)

    # Cheapest test that the detached launch will succeed: attempt the
    # same HttpListener it will use.
    $probe = [System.Net.HttpListener]::new()
    $probe.Prefixes.Add("http://*:$Port/")
    try {
        $probe.Start(); $probe.Stop(); $probe.Close()
        return   # port is free
    } catch {
        try { $probe.Close() } catch { Write-Debug $_ }
    }

    $diag = ''
    $holderPids = @(Get-PortListenerPid -Port $Port -Diagnostic ([ref]$diag))
    if (-not $holderPids.Count) {
        Write-Warning "Port $Port is in use but the OS did not expose a PID (netsh/lsof unavailable or empty)."
        if ($diag) { Write-Warning "  Diagnostic: $diag" }
        Write-Warning "Stop the conflicting listener manually and rerun:"
        Write-Warning "  Windows: netsh http show servicestate"
        Write-Warning "  Unix:    lsof -iTCP:$Port -sTCP:LISTEN  (or: sudo lsof -nP -iTCP:$Port)"
        exit 1
    }

    foreach ($holderPid in $holderPids) {
        $proc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }   # exited since the OS query
        if ($proc.ProcessName -notmatch '^(pwsh|PowerShell|powershell)$') {
            Write-Warning "Port $Port is held by PID $holderPid ($($proc.ProcessName)) — not a pwsh process."
            Write-Warning "Refusing to kill an unrelated listener. Stop it manually (Stop-Process -Id $holderPid) and rerun."
            exit 1
        }
        Write-Output "Port $Port held by orphan pwsh PID $holderPid (started $($proc.StartTime)). Stopping it."
        Stop-Process -Id $holderPid -Force -ErrorAction SilentlyContinue
    }

    # HTTP.sys releases the URL reservation async after the owner exits;
    # poll briefly until the probe succeeds.
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 300
        $probe = [System.Net.HttpListener]::new()
        $probe.Prefixes.Add("http://*:$Port/")
        try {
            $probe.Start(); $probe.Stop(); $probe.Close()
            Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
            return
        } catch {
            try { $probe.Close() } catch { Write-Debug $_ }
        }
    }
    Write-Warning "Port $Port is still held after stopping the orphan pwsh holder(s)."
    Write-Warning "Inspect with 'netsh http show servicestate' (or 'lsof -iTCP:$Port -sTCP:LISTEN') and retry."
    exit 1
}
Resolve-PortOrphan -Port $Port -PidFile $PidFile

# --- Ensure repoUrl is set in status.json ---
$StatusFile = Join-Path $TrackDir "status.json"
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
            $statusDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $StatusFile -Encoding utf8
            Write-Output "Set repoUrl in status.json: $repoUrl"
        }
    } catch {
        Write-Warning "Could not update repoUrl in status.json: $_"
    }
}

# --- Clean up leftovers from older layouts ---
# server.heartbeat: server no longer reads this; tidy up so inspectors
# don't think it's load-bearing.
# Legacy paths directly under test/status/: pre-track-dir layout wrote
# server.pid, runner.pid, status.json, server.err, current-action.json,
# control.*-pause, .status-server.ps1 there. An upgrade leaves those as
# untracked (no longer .gitignored), cluttering `git status`. Drop them
# on every start so operator runs land on a clean status dir.
Remove-Item (Join-Path $StatusDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $TrackDir  'server.heartbeat') -Force -ErrorAction SilentlyContinue
foreach ($legacyName in @('server.pid','runner.pid','status.json','server.err','current-action.json',
                          'control.pause','control.step-pause','control.cycle-pause','.status-server.ps1')) {
    Remove-Item (Join-Path $StatusDir $legacyName) -Force -ErrorAction SilentlyContinue
}

# --- Enumerate host IPs → $env:YURUNA_TRACK_DIR/ipaddresses.txt ---
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
# run. File is overwritten on every Start-StatusServer invocation so
# stale entries from a previous host/network are not preserved.
$IpAddressesFile = Join-Path $TrackDir "ipaddresses.txt"
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

# --- Detect host type ---
# $detectedHost is captured at parent startup and threaded into the
# detached server's here-string (as $serverHostType) so the per-host
# folder lookup at /control/guest-folders can find host/<short>/guest.*.
# Host-SSH-server enable/disable is no longer a UI button: it lives in
# the host-ssh-server extension, driven by Invoke-TestInnerRunner from
# test.config.yml's hostSshServer.enabled key.
$detectedHost = ''
try {
    $hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
    if (Test-Path $hostModPath) {
        Import-Module -Name $hostModPath -Force
        $detectedHost = Get-HostType
    }
} catch {
    Write-Warning "Host-type detection failed (continuing with HTTP status server): $_"
}

# --- Probe proxy cache → $env:YURUNA_TRACK_DIR/caching-proxy.txt ---
# UI banner appends this string to the status text so viewers see at a
# glance whether the harness is behind a local squid. File holds
# ready-to-embed HTML (including <a href> to cachemgr URL) so the UI
# injects it without knowing the URL format. Written once at
# Start-StatusServer — restart to refresh after bringing squid up/down.
# Needs $detectedHost, so runs AFTER the SSH block's host detection.
$CachingProxyFile = Join-Path $TrackDir "caching-proxy.txt"
try {
    if ($detectedHost) {
        Import-Module (Join-Path $ModulesDir 'Test.Host.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $TestRoot) -HostType $detectedHost)
        # Re-import Test.CachingProxy with -Global -Force here even though
        # line 55 already imported it once: Initialize-YurunaHost cascades
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
                    }
                    # macOS: port 80 (<1024) is managed exclusively by
                    # Start-CachingProxy.ps1 (it calls `sudo -v` first). Including
                    # it here would trigger a sudo prompt on every status-server
                    # restart. On macOS each port is independent (per-port pidfile),
                    # so excluding :80 does not affect the other ports.
                    # Windows: all ports in one list — netsh clears everything first.
                    # All squid-cache port mappings are repeated in EVERY caller's
                    # list because Add-CachingProxyPortMap clears ALL Yuruna netsh /
                    # pwsh-forwarder / firewall state first; omitting any here
                    # would tear it down each status-server restart.
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
                        $squidPorts = if ($IsMacOS) { @(3000) } else { @(80, 3000, $cacheHttpPort, $cacheHttpsPort) }
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
                $dashboardUrl = "http://${bestIp}:3000/d/yuruna-squid/squid-cache-yuruna?orgId=1&from=now-2h&to=now&timezone=browser&refresh=1m"
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

# --- Launch the server as a detached process ---
$serverScript = @"
`$ErrorActionPreference = 'Stop'
`$listener = [System.Net.HttpListener]::new()
`$listener.Prefixes.Add('http://*:$Port/')
`$statusDir = '$($StatusDir -replace "'","''")'
`$trackDir  = '$($TrackDir  -replace "'","''")'
`$logDir    = '$($LogDir    -replace "'","''")'
`$repoRoot  = '$($RepoRoot  -replace "'","''")'
`$stepPauseFile  = Join-Path `$trackDir 'control.step-pause'
`$cyclePauseFile = Join-Path `$trackDir 'control.cycle-pause'
`$statusJsonFile = Join-Path `$trackDir 'status.json'
`$serverLogFile  = Join-Path `$trackDir 'server.err'
# $serverHostType is the parent-detected host type baked into the
# detached server's here-string. Used by /control/guest-folders to list
# guests under host/<short>/. SSH-server toggle endpoints used to live
# in this script; they were moved to the host-ssh-server extension and
# the parent runner now drives state from test.config.yml at cycle start.
`$serverHostType = '$detectedHost'
# NOTE: server used to self-exit on stale server.heartbeat. Removed
# because legitimate runner states outlast ANY threshold — a
# prompt-for-confirmation pausing the runner for hours, or a single
# waitForText with timeoutSeconds:3600. UI must stay up, so the ONLY
# stop path is Stop-StatusServer.ps1 (kills server.pid). A truly
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
    while (`$listener.IsListening) {
      # Outer try/catch: any throw below MUST NOT kill the server.
      # Previously `$listener.EndGetContext(...)` sat outside the inner
      # try, so transient HttpListenerException (client reset, malformed
      # request, http.sys hiccup) unwound to the outer try/finally and
      # exited with no log. Wrap the whole iteration; log + continue.
      try {
        # Block indefinitely for the next request. No periodic wake-up
        # needed now that the heartbeat-stale self-exit is gone.
        `$ctx = `$listener.GetContext()
        try {
            `$req  = `$ctx.Request
            `$res  = `$ctx.Response
            `$res.Headers.Add('Access-Control-Allow-Origin', '*')
            `$path = `$req.Url.LocalPath.TrimStart('/')
            if (`$path -eq '' -or `$path -eq 'status/' -or `$path -eq 'status') { `$path = 'index.html' }
            `$path = `$path -replace '^status[/\\]', ''

            # --- /control/test-config: read/write test.config.yml from UI ---
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
                        `$doc  = Get-Content -Raw -LiteralPath `$testConfigFile | ConvertFrom-Yaml -Ordered
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
                    `$tmp = "`$testConfigFile.tmp"
                    `$writeOk = `$false
                    try {
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

            # --- /control/guest-folders: list guest.* dirs under current host ---
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

            # --- /control/runner-status: is Invoke-TestRunner actually alive? ---
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
                `$runnerPidFile   = Join-Path `$trackDir 'runner.pid'
                `$runnerStartFile = Join-Path `$trackDir 'runner.start'
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

            # --- Control endpoints: Pause/Continue back-channel from UI ---
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
                    `$doc = Get-Content -Raw `$statusJsonFile -ErrorAction Stop | ConvertFrom-Json -AsHashtable
                    `$doc[`$fieldName] = `$desiredPaused
                    `$tmp = "`$statusJsonFile.tmp"
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

            # --- /livecheck — cheap reachability probe for guests ---
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
                    service = 'yuruna-status-server'
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

            # --- /diagnostics/<folder>/<filename> — guest-pushed diagnostic dump ---
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
            # so it lines up with Test.Diagnostic' Get-DiagnosticsFileName
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

            # --- /yuruna-archive.tar.gz — committed-content tarball ---
            # Replaces ``git clone`` for guests in the dev iteration loop:
            # ``git archive --format=tar.gz HEAD`` streams a tarball of
            # the latest committed tree, no .git/, no working-tree
            # uncommitted noise. Sidesteps the deny-list (which forbids
            # .git/) since it does not expose the repo internals.
            if (`$path -eq 'yuruna-archive.tar.gz') {
                `$tmp = [System.IO.Path]::GetTempFileName()
                try {
                    & git -C `$repoRoot archive --format=tar.gz -o `$tmp HEAD 2>`$null
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
                }
                continue
            }

            # --- /yuruna-project-archive.tar.gz — project repo tarball ---
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
                `$tmp = [System.IO.Path]::GetTempFileName()
                try {
                    & git -C `$projectRoot archive --format=tar.gz -o `$tmp HEAD 2>`$null
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
                }
                continue
            }

            # Dispatch by URL prefix:
            #   yuruna-repo/<rel> -> `$repoRoot (working tree, with deny-list)
            #   track/<name>      -> `$trackDir  (pids, status.json, control
            #                                    flags, ipaddresses.txt,
            #                                    caching-proxy.txt,
            #                                    current-action.json, server.err)
            #   log/<name>        -> `$logDir    (HTML transcripts, OCR /
            #                                    screenshot debug, failure captures)
            #   <anything>        -> `$statusDir (index.html, template, static assets)
            # Each branch pins the resolved file under its mount root
            # via a StartsWith check — traversal like
            # track/../../../etc/passwd can't escape.
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
                    'test/extension/authentication/vault.yml',
                    '*/vault.lock',
                    '*/notification.transports.yml',
                    'test/extension/notification/notification.transports.yml',
                    '*.events.log',
                    'test/status/track/extension/*',
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
            } elseif (`$path -like 'track/*') {
                `$rel  = `$path.Substring(6)
                `$root = `$trackDir
                # Pattern-based deny under /track/ for credential event
                # logs and any future *-password.txt sidecars.
                `$relNorm = `$rel -replace '\\','/'
                `$denyLikeTrack = @(
                    'extension/*',
                    '*.events.log',
                    '*-password.txt'
                )
                `$denied = `$false
                foreach (`$pat in `$denyLikeTrack) {
                    if (`$relNorm -like `$pat) { `$denied = `$true; break }
                }
                if (`$denied) {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden (deny-list)')
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
            } elseif (`$path -like 'log/*') {
                `$rel  = `$path.Substring(4)
                `$root = `$logDir
            } else {
                `$rel  = `$path
                `$root = `$statusDir
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
            # --- Directory listing ---
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
                [void]`$sb.AppendLine('<!doctype html><html><head><meta charset="utf-8"><title>Index of ' + `$titleEnc + '</title><style>body{font-family:sans-serif;margin:1.5em}h1{font-size:1.1em}table{border-collapse:collapse}td,th{padding:0.2em 1em;border-bottom:1px solid #eee;font-family:monospace;text-align:left}th{background:#f4f4f4}</style></head><body>')
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
                # .yaml, .md) where a host edit + Start-StatusServer
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
$serverScriptFile = Join-Path $TrackDir ".status-server.ps1"
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
    $serverOut = Join-Path $TrackDir "server.out"
    $serverErrFile = Join-Path $TrackDir "server.err"
    $proc = Start-Process -FilePath "pwsh" `
        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $serverScriptFile `
        -RedirectStandardOutput $serverOut `
        -RedirectStandardError  $serverErrFile `
        -PassThru
    Set-Content -Path $PidFile -Value $proc.Id
} else {
    # On macOS/Linux, launch via bash to fully detach from the parent session.
    # The subshell (...) + & backgrounds the process in a new process group,
    # and nohup prevents SIGHUP from killing it when the caller exits.
    $stdErr = Join-Path $TrackDir "server.err"
    & bash -c "nohup pwsh -NoProfile -File '$serverScriptFile' > /dev/null 2>'$stdErr' & echo `$!"  | Set-Variable -Name bgPid
    Set-Content -Path $PidFile -Value $bgPid
}

# --- Verify server started ---
$serverReady = $false
for ($i = 0; $i -lt 5; $i++) {
    Start-Sleep -Seconds 1
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:$Port/status/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
        $serverReady = $true
        break
    } catch { Write-Output "  Waiting for server... ($($i + 1)/5)" }
}
if (-not $serverReady) {
    Write-Warning "Status server process started but port $Port is not responding after 5 seconds."
    Write-Warning "Check the server error log: $(Join-Path $TrackDir 'server.err')"
}

# --- Display connection info ---
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

# --- LAN reachability pre-check (Windows only) ---
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

Write-Output "Stop with: .\Stop-StatusServer.ps1"
