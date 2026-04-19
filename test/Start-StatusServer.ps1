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
    A PID file (status/server.pid) is written so Stop-StatusServer.ps1
    can shut it down later.

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
$TestRoot  = $PSScriptRoot
$StatusDir = Join-Path $TestRoot "status"
$PidFile   = Join-Path $StatusDir "server.pid"
$ModulesDir = Join-Path $TestRoot "modules"

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
$StatusFile = Join-Path $StatusDir "status.json"
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

# --- Clear any leftover heartbeat file from an older build that used it ---
# The server no longer reads this file; just tidy it up so inspectors don't
# think it's load-bearing.
Remove-Item (Join-Path $StatusDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue

# --- Enumerate host IP addresses and write them to status/log/ipaddresses.txt ---
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
$LogDir = Join-Path $StatusDir "log"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$IpAddressesFile = Join-Path $LogDir "ipaddresses.txt"
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
# "Proxy cache: detected/not detected" line — so the user knows on startup
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

# --- Probe for proxy cache and record state to status/log/proxy-cache.txt ---
# The UI banner appends this string to the status text so a viewer can see
# at a glance whether the harness is behind a local squid. The file holds
# ready-to-embed HTML (including an <a href> to the cachemgr URL) so the
# UI can inject it without knowing the URL format. Written once at
# Start-StatusServer time — restart the server to refresh after bringing
# the squid cache up or down. Needs $detectedHost, so runs AFTER the SSH
# block that performs host detection.
$ProxyCacheFile = Join-Path $LogDir "proxy-cache.txt"
try {
    $proxyCacheModPath = Join-Path $ModulesDir "Test.ProxyCache.psm1"
    if ((Test-Path $proxyCacheModPath) -and $detectedHost) {
        Import-Module -Name $proxyCacheModPath -Force
        $proxyCacheUrl = Test-ProxyCacheAvailable -HostType $detectedHost
        if ($proxyCacheUrl) {
            # $proxyCacheUrl looks like "http://192.168.64.5:3128".
            $proxyUri = [uri]$proxyCacheUrl
            $proxyManagerUrl = "http://$($proxyUri.Host)/cgi-bin/cachemgr.cgi"
            $proxyCacheContent = 'Proxy cache: <a href="' + $proxyManagerUrl + '" target="_blank">' + $proxyCacheUrl + '</a>'
            Write-Output "Proxy cache: $proxyCacheUrl (manager: $proxyManagerUrl) — written to $ProxyCacheFile"
        } else {
            $proxyCacheContent = 'Proxy cache: not detected'
            Write-Output "Proxy cache: not detected — written to $ProxyCacheFile"
        }
        [System.IO.File]::WriteAllText($ProxyCacheFile, $proxyCacheContent, [System.Text.UTF8Encoding]::new($false))
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
`$pauseFile     = Join-Path '$($StatusDir -replace "'","''")' 'control.pause'
`$statusJsonFile = Join-Path '$($StatusDir -replace "'","''")' 'status.json'
`$serverLogFile = Join-Path '$($StatusDir -replace "'","''")' 'server.err'
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
            # Creating/removing control.pause is the source of truth checked by
            # Invoke-Sequence on every step iteration; we also mirror the flag
            # into status.json so the next UI poll flips the banner immediately
            # (the normal parent-side Write-StatusJson will keep it in sync
            # thereafter by re-reading the file each write).
            if (`$path -eq 'control/pause' -or `$path -eq 'control/resume') {
                `$desiredPaused = (`$path -eq 'control/pause')
                try {
                    if (`$desiredPaused) {
                        Set-Content -Path `$pauseFile -Value (Get-Date -Format o) -ErrorAction SilentlyContinue
                    } else {
                        Remove-Item `$pauseFile -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
                try {
                    `$doc = Get-Content -Raw `$statusJsonFile -ErrorAction Stop | ConvertFrom-Json -AsHashtable
                    `$doc['paused'] = `$desiredPaused
                    `$tmp = "`$statusJsonFile.tmp"
                    `$doc | ConvertTo-Json -Depth 20 | Set-Content -Path `$tmp -Encoding utf8
                    Move-Item -Path `$tmp -Destination `$statusJsonFile -Force
                } catch { }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$payload = if (`$desiredPaused) { '{"ok":true,"paused":true}' } else { '{"ok":true,"paused":false}' }
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            `$file = Join-Path '$($StatusDir -replace "'","''")' `$path
            `$file = [System.IO.Path]::GetFullPath(`$file)
            if (-not `$file.StartsWith('$($StatusDir -replace "'","''")')) {
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

$encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($serverScript))

if ($IsWindows) {
    $proc = Start-Process -FilePath "pwsh" `
        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encodedCommand `
        -PassThru
    Set-Content -Path $PidFile -Value $proc.Id
} else {
    # On macOS/Linux, launch via bash to fully detach from the parent session.
    # The subshell (...) + & backgrounds the process in a new process group,
    # and nohup prevents SIGHUP from killing it when the caller exits.
    $stdErr = Join-Path $StatusDir "server.err"
    & bash -c "nohup pwsh -NoProfile -EncodedCommand $encodedCommand > /dev/null 2>'$stdErr' & echo `$!"  | Set-Variable -Name bgPid
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
    Write-Warning "Check the server error log: $(Join-Path $StatusDir 'server.err')"
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
Write-Output "Stop with: .\Stop-StatusServer.ps1"
