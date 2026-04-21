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
$StatusDir  = Join-Path $TestRoot "status"
$ModulesDir = Join-Path $TestRoot "modules"

# Resolve $env:YURUNA_TRACK_DIR (runtime state) and $env:YURUNA_LOG_DIR
# (transcripts / debug artifacts). Both default to subdirs of status/ so
# the status HTTP server can serve them directly at /track/* and /log/*.
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
        # Verify the PID belongs to a pwsh process (not a recycled PID from something else)
        if ($proc -and $proc.ProcessName -match 'pwsh|PowerShell') {
            # Confirm the port is actually responding
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
            $RepoRoot = Split-Path -Parent $TestRoot
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
# server.heartbeat: the server no longer reads this file; just tidy it up
# so inspectors don't think it's load-bearing.
# Legacy paths directly under test/status/: pre-track-dir layout wrote
# server.pid, runner.pid, status.json, server.err, current-action.json,
# control.*-pause, .status-server.ps1 there. An upgrade from that layout
# leaves those as untracked files (no longer .gitignored) which would
# clutter `git status`. Drop them on every start so the next operator run
# lands on a clean status dir.
Remove-Item (Join-Path $StatusDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $TrackDir  'server.heartbeat') -Force -ErrorAction SilentlyContinue
foreach ($legacyName in @('server.pid','runner.pid','status.json','server.err','current-action.json',
                          'control.pause','control.step-pause','control.cycle-pause','.status-server.ps1')) {
    Remove-Item (Join-Path $StatusDir $legacyName) -Force -ErrorAction SilentlyContinue
}

# --- Enumerate host IP addresses and write them to $env:YURUNA_TRACK_DIR/ipaddresses.txt ---
# The UI footer reads this file to show where the server is reachable from
# other machines. Loopback (127.0.0.1, ::1) is excluded because it's
# trivially useless for remote clients — if you're reading the page from
# somewhere you already know the address you used to reach it.
#
# File format:
#   * No addresses detected  → single line "No IP addresses detected"
#   * Addresses detected     → up to two lines:
#       line 1: IPv4 addresses, comma-separated (omitted if none)
#       line 2: IPv6 addresses, comma-separated (omitted if none)
#
# Splitting IPv4 / IPv6 onto their own lines lets the UI render them as
# two short rows instead of one long run, and the file is overwritten on
# every Start-StatusServer invocation so stale entries from a previous
# host/network are not preserved.
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
        # LF, not CRLF — browsers treat the whole thing as text and the UI
        # splits on \n; keeping a single line terminator style avoids
        # \r leaking into the rendered strings.
        $fileContent = ($lines -join "`n")
        $reportCount = $ipv4.Count + $ipv6.Count
    }
    # UTF-8 without BOM so a browser fetch() yields a clean string.
    [System.IO.File]::WriteAllText($IpAddressesFile, $fileContent, [System.Text.UTF8Encoding]::new($false))
    Write-Output "IP addresses ($reportCount): written to $IpAddressesFile"
} catch {
    Write-Warning "Failed to enumerate/write IP addresses: $_"
    # Best-effort: leave a previous file intact if there was one.
}


# --- Report SSH-server availability (no install attempted here) ---
# Start-StatusServer used to auto-install OpenSSH, which made the first
# invocation on a fresh host feel hung for several minutes inside
# Add-WindowsCapability. That install is now externalized to
# test/Start-SshServer.ps1, which the admin runs once explicitly. Here we
# just probe the state and log it — same pattern as Invoke-TestRunner's
# "Caching proxy: detected/not detected" line — so the user knows on startup
# whether SSH is ready without waiting for the detached HTTP server.
#
# $detectedHost is also threaded into the detached server's here-string so
# the control/ssh/* endpoints know which dispatcher arm to call.
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

# --- Probe for proxy cache and record state to $env:YURUNA_TRACK_DIR/caching-proxy.txt ---
# The UI banner appends this string to the status text so a viewer can see
# at a glance whether the harness is behind a local squid. The file holds
# ready-to-embed HTML (including an <a href> to the cachemgr URL) so the
# UI can inject it without knowing the URL format. Written once at
# Start-StatusServer time — restart the server to refresh after bringing
# the squid cache up or down. Needs $detectedHost, so runs AFTER the SSH
# block that performs host detection.
$CachingProxyFile = Join-Path $TrackDir "caching-proxy.txt"
try {
    $cachingProxyModPath = Join-Path $ModulesDir "Test.CachingProxy.psm1"
    if ((Test-Path $cachingProxyModPath) -and $detectedHost) {
        Import-Module -Name $cachingProxyModPath -Force
        $cachingProxyUrl = Test-CachingProxyAvailable -HostType $detectedHost
        if ($cachingProxyUrl) {
            # Attempt port mapping so the status-page banner reports the
            # same success/failure state Invoke-TestRunner prints. Add-
            # CachingProxyPortMap dispatches per-platform via Test.PortMap
            # — netsh portproxy on Hyper-V, detached TcpListener
            # forwarders on macOS/UTM. Both channels end up reading the
            # same caching-proxy.txt so the status-page banner is in lock-
            # step with the console.
            #
            # Port list @(80, 3128, 3129, 3000) on both platforms MUST
            # match Invoke-TestRunner.ps1 and Start-CachingProxy.ps1 — Add-
            # CachingProxyPortMap runs Clear-AllCachingProxyPortMapping first,
            # so a narrower list here would tear down ports the other
            # callers just set up.
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
                    # directly in the dashboard link. Clear any stale
                    # local mapping from a prior local-cache cycle.
                    [void](Remove-CachingProxyPortMap)
                    $bestIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                    $mapOk = [bool]$bestIp
                } else {
                    # Local-cache port-map target IP: on Windows, Test-
                    # ProxyCacheAvailable returns the VM's direct IP
                    # (Hyper-V Default Switch is reachable from the host),
                    # so parsing it out works. On macOS the URL is
                    # http://192.168.64.1:3128 — the VZ-gateway URL
                    # guests use, NOT the cache VM — and feeding
                    # 192.168.64.1 to Start-CachingProxyForwarder would make the
                    # forwarder tunnel to its own listen socket (self-
                    # loop: TCP accepts succeed, nothing reaches squid,
                    # subiquity sees "Connection failed [IP: 192.168.64.1
                    # 3128]" and falls back to an offline install). Read
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
                    $squidPorts = @(80, 3128, 3129, 3000)
                    if ($vmIp) {
                        $mapResult = Add-CachingProxyPortMap -VMIp $vmIp -Port $squidPorts
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
                # Escape & in the query string for strict HTML-attribute
                # correctness — the injection is via .innerHTML so lenient
                # parsers work either way, but strict ones may trip on
                # bare `&` adjacent to entity-like sequences.
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
`$stepPauseFile  = Join-Path `$trackDir 'control.step-pause'
`$cyclePauseFile = Join-Path `$trackDir 'control.cycle-pause'
`$statusJsonFile = Join-Path `$trackDir 'status.json'
`$serverLogFile  = Join-Path `$trackDir 'server.err'
# --- SSH-toggle endpoints: need Test.SshServer in this process too ---
# control/ssh/{status,enable,disable} is handled inline below; importing the
# module at listener start means each request is just a function call, not
# a child pwsh spawn. $sshHostType is captured from Get-HostType at parent
# startup and baked into this script via the here-string.
`$sshModPath  = Join-Path '$($ModulesDir -replace "'","''")' 'Test.SshServer.psm1'
`$sshHostType = '$detectedHost'
`$sshReady    = `$false
if (Test-Path `$sshModPath) {
    try {
        Import-Module -Name `$sshModPath -Force -ErrorAction Stop
        `$sshReady = `$true
    } catch {
        # Can't use Write-ServerErr yet — it's defined below. Defer log.
        `$sshImportErr = `$_.Exception.Message
    }
}
# NOTE: the server used to self-exit when server.heartbeat went stale. That
# was removed because legitimate runner states can outlast ANY threshold —
# e.g. a prompt-for-confirmation that pauses the runner for hours, or a
# single waitForText with timeoutSeconds:3600. The UI must stay up across
# those cases, so the ONLY valid stop path is now Stop-StatusServer.ps1
# (which kills the PID recorded in server.pid). A truly orphaned server
# has to be killed manually — the trade-off is explicit and deliberate.
# Log any per-iteration exception so we can actually see why the server died.
# On Windows, Start-Process -WindowStyle Hidden has no stderr redirection, so
# without this file an unhandled throw in the loop dies silently — which was
# exactly the prior failure mode where the server vanished mid-run with no
# trace. Keep the log bounded so it can't fill the status dir indefinitely.
function Write-ServerErr {
    param([string]`$msg)
    try {
        if ((Test-Path `$serverLogFile) -and ((Get-Item `$serverLogFile).Length -gt 1MB)) {
            Move-Item -Path `$serverLogFile -Destination "`$serverLogFile.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path `$serverLogFile -Value "[`$(Get-Date -Format o)] `$msg" -ErrorAction SilentlyContinue
    } catch { }
}
try {
    `$listener.Start()
    Write-ServerErr "listener started on http://*:$Port/ (pid `$PID)"
    if (`$sshImportErr) { Write-ServerErr "Test.SshServer import failed: `$sshImportErr" }
    Write-ServerErr "ssh support: hostType='`$sshHostType' moduleReady=`$sshReady"
    while (`$listener.IsListening) {
      # Outer try/catch: any throw below MUST NOT kill the server. Previously
      # `$listener.EndGetContext(...)` sat outside the inner try, so transient
      # HttpListenerException (client reset, malformed request, http.sys
      # hiccup) unwound to the outer try/finally and exited the process with
      # no log. Wrap the whole iteration here; log + continue.
      try {
        # Block indefinitely for the next request. No periodic wake-up is
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
            # Three endpoints, one handler: status reads current state, enable
            # and disable mutate it. The JSON response always carries the full
            # {supported, enabled, ok, message} quadruple so the UI can settle
            # the button on a single reply (no follow-up status fetch needed).
            # supported=false short-circuits any mutate attempt — the UI
            # already disables the button in that case, so this is belt-and-
            # braces against direct curl hits.
            if (`$path -eq 'control/ssh/status' -or `$path -eq 'control/ssh/enable' -or `$path -eq 'control/ssh/disable') {
                # Three axes drive the UI button:
                #   supported — host-type has an implementation at all
                #   installed — OpenSSH is present on this machine
                #   enabled   — sshd service is currently Running
                # The button is disabled unless (supported && installed), and
                # its label flips on `enabled`. enable/disable endpoints are
                # short-circuited when OpenSSH isn't installed, because the
                # user must run test/Start-SshServer.ps1 to install first.
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

            # --- Control endpoints: Pause/Continue back-channel from the UI ---
            # Two independent pause switches, each backed by its own flag file
            # and mirrored into status.json so the next UI poll flips the
            # banner immediately:
            #   control.step-pause  — checked by Invoke-Sequence at every step
            #                         boundary; stops the test after the
            #                         currently running step finishes.
            #   control.cycle-pause — checked by Invoke-TestRunner at the
            #                         cycle boundary; stops the runner after
            #                         the current cycle finishes cleanup.
            # The normal parent-side Write-StatusJson keeps both flags in
            # sync thereafter by re-reading the files on each write.
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
                } catch { }
                try {
                    `$doc = Get-Content -Raw `$statusJsonFile -ErrorAction Stop | ConvertFrom-Json -AsHashtable
                    `$doc[`$fieldName] = `$desiredPaused
                    `$tmp = "`$statusJsonFile.tmp"
                    `$doc | ConvertTo-Json -Depth 20 | Set-Content -Path `$tmp -Encoding utf8
                    Move-Item -Path `$tmp -Destination `$statusJsonFile -Force
                } catch { }
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

            # Dispatch by URL prefix:
            #   track/<name> -> `$trackDir  (pids, status.json, control flags,
            #                              ipaddresses.txt, caching-proxy.txt,
            #                              current-action.json, server.err)
            #   log/<name>   -> `$logDir    (HTML transcripts, OCR / screenshot
            #                              debug artifacts, failure captures)
            #   <anything>   -> `$statusDir (index.html, status.json.template,
            #                              other committed static assets)
            # Each branch pins the resolved file under its mount root via a
            # StartsWith check so a traversal like track/../../../etc/passwd
            # can't escape into the repo or the filesystem.
            if (`$path -like 'track/*') {
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
            if (Test-Path `$file -PathType Leaf) {
                `$ext = [System.IO.Path]::GetExtension(`$file)
                `$res.ContentType = switch (`$ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.txt'  { 'text/plain; charset=utf-8' }
                    '.png'  { 'image/png' }
                    default { 'application/octet-stream' }
                }
                if (`$ext -eq '.json') {
                    `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                    `$res.Headers.Add('Pragma', 'no-cache')
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
            try { `$ctx.Response.Abort() } catch { }
        }
      } catch {
        # Log any unhandled iteration-level failure (EndGetContext throws,
        # listener kicked out by http.sys, etc.) and keep serving. Without
        # this the server used to die silently on the first transient blip.
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
Set-Content -Path $serverScriptFile -Value $serverScript -Encoding UTF8

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
            Write-Warning "    pwsh vde\host.windows.hyper-v\Enable-TestAutomation.ps1"
        }
    } catch {
        Write-Verbose "Firewall-rule reachability check skipped: $($_.Exception.Message)"
    }
}

Write-Output "Stop with: .\Stop-StatusServer.ps1"
