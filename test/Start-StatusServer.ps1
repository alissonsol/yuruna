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
#>

param(
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$TestRoot  = $PSScriptRoot
$StatusDir = Join-Path $TestRoot "status"
$PidFile   = Join-Path $StatusDir "server.pid"

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

# --- Launch the server as a detached process ---
$serverScript = @"
`$ErrorActionPreference = 'Stop'
`$listener = [System.Net.HttpListener]::new()
`$listener.Prefixes.Add('http://*:$Port/')
try {
    `$listener.Start()
    while (`$listener.IsListening) {
        `$ctx = `$listener.GetContext()
        try {
            `$req  = `$ctx.Request
            `$res  = `$ctx.Response
            `$res.Headers.Add('Access-Control-Allow-Origin', '*')
            `$path = `$req.Url.LocalPath.TrimStart('/')
            if (`$path -eq '' -or `$path -eq 'status/' -or `$path -eq 'status') { `$path = 'index.html' }
            `$path = `$path -replace '^status[/\\]', ''
            `$file = Join-Path '$($StatusDir -replace "'","''")' `$path
            if (Test-Path `$file -PathType Leaf) {
                `$ext = [System.IO.Path]::GetExtension(`$file)
                `$res.ContentType = switch (`$ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.txt'  { 'text/plain; charset=utf-8' }
                    default { 'application/octet-stream' }
                }
                if (`$ext -eq '.json') {
                    `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                    `$res.Headers.Add('Pragma', 'no-cache')
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
    }
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
