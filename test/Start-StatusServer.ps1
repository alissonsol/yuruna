<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456740
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
    Starts the status HTTP server as an independent background process.

.DESCRIPTION
    Launches a detached pwsh process that serves the test/status/ directory
    over HTTP. The server keeps running even if the caller exits.
    A PID file ($env:YURUNA_TRACK_DIR/server.pid) is written so
    Stop-StatusServer.ps1 can shut it down later.

.PARAMETER Port
    TCP port to listen on. Defaults to the value in test-config.json,
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
Import-Module (Join-Path $ModulesDir "Test.TrackDir.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1")   -Force
$null = Initialize-YurunaTrackDir
$null = Initialize-YurunaLogDir
$TrackDir = $env:YURUNA_TRACK_DIR
$LogDir   = $env:YURUNA_LOG_DIR

$PidFile = Join-Path $TrackDir "server.pid"

# --- Read port from config if not provided ---
if ($Port -eq 0) {
    $configPath = Join-Path $TestRoot "test-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Raw $configPath | ConvertFrom-Json
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
        $configPath = Join-Path $TestRoot "test-config.json"
        $config = $null
        if (Test-Path $configPath) {
            try { $config = Get-Content -Raw $configPath | ConvertFrom-Json } catch { Write-Verbose "Could not parse test-config.json: $_" }
        }
        $repoUrl = $null
        if ($config -and $config.repoUrl) { $repoUrl = $config.repoUrl }
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


# --- Report SSH-server availability (no install here) ---
# Start-StatusServer used to auto-install OpenSSH, making the first
# invocation on a fresh host feel hung for several minutes inside
# Add-WindowsCapability. Install is now in test/Start-SshServer.ps1 —
# the admin runs it once explicitly. Here we just probe + log — same
# pattern as "Caching proxy: detected/not detected" — so the user
# knows on startup whether SSH is ready.
#
# $detectedHost is threaded into the detached server's here-string so
# /control/ssh/* endpoints know which dispatcher arm to call.
$detectedHost = ''
try {
    $hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
    $sshModPath  = Join-Path $ModulesDir "Test.SshServer.psm1"
    if ((Test-Path $hostModPath) -and (Test-Path $sshModPath)) {
        Import-Module -Name $hostModPath -Force
        Import-Module -Name $sshModPath  -Force
        $detectedHost = Get-HostType
        if ($detectedHost) {
            if (-not (Test-SshServerSupported -HostType $detectedHost)) {
                Write-Output "SSH server: not supported on $detectedHost (status-page button will be disabled)"
            } elseif (-not (Test-SshServerInstalled -HostType $detectedHost)) {
                Write-Output "SSH server: not installed (run test/Start-SshServer.ps1 to install)"
            } elseif (Test-SshServerEnabled -HostType $detectedHost) {
                Write-Output "SSH server: installed and running"
            } else {
                Write-Output "SSH server: installed but stopped (status-page button can start it)"
            }
        }
    } else {
        Write-Warning "SSH-server check skipped — modules not found (Test.Host.psm1 / Test.SshServer.psm1)."
    }
} catch {
    Write-Warning "SSH-server check failed (continuing with HTTP status server): $_"
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
    $cachingProxyModPath = Join-Path $ModulesDir "Test.CachingProxy.psm1"
    if ((Test-Path $cachingProxyModPath) -and $detectedHost) {
        Import-Module -Name $cachingProxyModPath -Force
        $cachingProxyUrl = Test-CachingProxyAvailable -HostType $detectedHost
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
            $portMapModPath = Join-Path $ModulesDir "Test.PortMap.psm1"
            $mapOk = $false
            $bestIp = $null
            $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_IP
            if (Test-Path $portMapModPath) {
                Import-Module -Name $portMapModPath -Force
                if ($isExternal) {
                    # Remote serves its own ports; surface the remote IP
                    # in the dashboard link. Clear any stale local
                    # mapping from a prior local-cache cycle.
                    [void](Remove-CachingProxyPortMap)
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
                    # the real VM IP from cache-ip.txt written by
                    # Start-CachingProxy.ps1.
                    if ($IsMacOS) {
                        $vmIp = $null
                        $cacheIpFile = Join-Path $HOME "virtual/squid-cache/cache-ip.txt"
                        if (Test-Path $cacheIpFile) {
                            $candidate = (Get-Content -Raw $cacheIpFile).Trim()
                            if ($candidate -match '^\d+\.\d+\.\d+\.\d+$') { $vmIp = $candidate }
                        }
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
                    #   8022 -> VM 22         : SSH on non-standard host port.
                    #   3128 -> VM 3138 PROXY : squid HTTP w/ real client IP preserved.
                    #   3129 -> VM 3139 PROXY : squid SSL-bump HTTPS w/ real client IP.
                    # macOS skips :80 — see Start-CachingProxy.ps1, port 80 is
                    # privileged-bind and Start-CachingProxy is the sole sudo owner.
                    $squidPorts = if ($IsMacOS) { @(3000) } else { @(80, 3000) }
                    if ($vmIp) {
                        $mapResult = Add-CachingProxyPortMap -VMIp $vmIp `
                                        -Port $squidPorts `
                                        -PortRemap @{8022 = 22; 3128 = 3138; 3129 = 3139} `
                                        -ProxyProtocolPort @(3128, 3129)
                        $mapOk = [bool]$mapResult
                    }
                    if ($mapOk) {
                        $bestIp = Get-BestHostIp
                        if (-not $bestIp) { $bestIp = $vmIp }  # routable-iface fallback
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
# --- SSH-toggle endpoints: Test.SshServer imported here too ---
# control/ssh/{status,enable,disable} handled inline below; importing
# at listener start means each request is a function call, not a child
# pwsh spawn. $sshHostType captured from Get-HostType at parent startup
# and baked into this script via the here-string.
`$sshModPath  = Join-Path '$($ModulesDir -replace "'","''")' 'Test.SshServer.psm1'
`$sshHostType = '$detectedHost'
`$sshReady    = `$false
if (Test-Path `$sshModPath) {
    try {
        Import-Module -Name `$sshModPath -Force -ErrorAction Stop
        `$sshReady = `$true
    } catch {
        # Can't use Write-ServerErr yet — defined below. Defer log.
        `$sshImportErr = `$_.Exception.Message
    }
}
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
    if (`$sshImportErr) { Write-ServerErr "Test.SshServer import failed: `$sshImportErr" }
    Write-ServerErr "ssh support: hostType='`$sshHostType' moduleReady=`$sshReady"
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

            # --- SSH-toggle back-channel ---
            # Three endpoints, one handler: status reads state;
            # enable/disable mutate. JSON response always carries
            # {supported, enabled, ok, message} so the UI settles the
            # button on a single reply. supported=false short-circuits
            # any mutate attempt — belt-and-braces against direct curl.
            if (`$path -eq 'control/ssh/status' -or `$path -eq 'control/ssh/enable' -or `$path -eq 'control/ssh/disable') {
                # Three axes drive the UI button:
                #   supported — host-type has an implementation
                #   installed — OpenSSH is present
                #   enabled   — sshd is currently Running
                # Button is disabled unless (supported && installed),
                # label flips on `enabled`. enable/disable short-circuit
                # when OpenSSH isn't installed — user must run
                # test/Start-SshServer.ps1 to install first.
                `$supported = `$false
                `$installed = `$false
                `$enabled   = `$false
                `$ok        = `$true
                `$msg       = ''
                if (`$sshReady -and (Get-Command Test-SshServerSupported -ErrorAction SilentlyContinue)) {
                    try { `$supported = [bool](Test-SshServerSupported -HostType `$sshHostType) } catch { `$supported = `$false }
                }
                if (`$supported -and (Get-Command Test-SshServerInstalled -ErrorAction SilentlyContinue)) {
                    try { `$installed = [bool](Test-SshServerInstalled -HostType `$sshHostType) } catch { `$installed = `$false }
                }
                if (`$supported -and `$installed) {
                    try {
                        if (`$path -eq 'control/ssh/enable') {
                            `$ok = [bool](Enable-SshServer -HostType `$sshHostType)
                        } elseif (`$path -eq 'control/ssh/disable') {
                            `$ok = [bool](Disable-SshServer -HostType `$sshHostType)
                        }
                        if (Get-Command Test-SshServerEnabled -ErrorAction SilentlyContinue) {
                            `$enabled = [bool](Test-SshServerEnabled -HostType `$sshHostType)
                        }
                    } catch {
                        `$ok = `$false
                        `$msg = `$_.Exception.Message
                        Write-ServerErr "ssh `$path failed: `$msg"
                    }
                } elseif (`$path -ne 'control/ssh/status') {
                    `$ok = `$false
                    if (-not `$supported) {
                        `$msg = 'SSH server toggle not supported on this host.'
                    } else {
                        `$msg = 'OpenSSH is not installed. Run test/Start-SshServer.ps1 first.'
                    }
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$payload = @{
                    ok        = `$ok
                    supported = `$supported
                    installed = `$installed
                    enabled   = `$enabled
                    message   = `$msg
                } | ConvertTo-Json -Compress
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
                # Deny-list: secrets and the .git directory. The user
                # opted into broad repo serving for fast iteration —
                # these specific paths still need to stay private even
                # on a localhost-bound server, since the dashboard URL
                # is also LAN-reachable when the firewall rule is open.
                if (`$rel -eq 'test/test-config.json' -or
                    `$rel -like '*.pfx' -or
                    `$rel -eq '.git' -or
                    `$rel -like '.git/*') {
                    `$res.StatusCode = 403
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden (deny-list)')
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
            } elseif (`$path -like 'track/*') {
                `$rel  = `$path.Substring(6)
                `$root = `$trackDir
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
                # No-cache on anything a proxy might stash stale.
                # .json (status.json, current-action.json, caching-proxy
                # results) mutates per cycle; .html/.txt (index.html,
                # ipaddresses.txt, caching-proxy.txt) change on git pull
                # or Start-StatusServer restart. Repo file types (.sh,
                # .ps1, .psm1, .yml, .yaml, .md) are served from the
                # working tree under /yuruna-repo/ for the dev iteration
                # loop, and must never be cached by a shared squid —
                # otherwise a host edit + Start-StatusServer restart
                # would be invisible to guests.
                if (`$ext -in '.html','.json','.txt','.css','.js','.sh','.ps1','.psm1','.yml','.yaml','.md') {
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
    $proc = Start-Process -FilePath "pwsh" `
        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $serverScriptFile `
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
                Write-Warning "LAN reachability: firewall rule '$ruleName' does not match TCP :$Port (test-config.json port may have changed)."
            }
            Write-Warning "  http://localhost:$Port/status/ will work, but LAN clients hitting"
            Write-Warning "  http://${ip}:$Port/status/ will time out."
            Write-Warning "  To fix, open a new elevated pwsh and run:"
            Write-Warning "    cd $(Split-Path -Parent $TestRoot)"
            Write-Warning "    pwsh virtual\host.windows.hyper-v\Enable-TestAutomation.ps1"
        }
    } catch {
        Write-Verbose "Firewall-rule reachability check skipped: $($_.Exception.Message)"
    }
}

Write-Output "Stop with: .\Stop-StatusServer.ps1"
