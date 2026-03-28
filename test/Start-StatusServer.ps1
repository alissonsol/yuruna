<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456740
.AUTHOR Alisson Sol
.COMPANYNAME None
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

# --- Stop any existing server ---
if (Test-Path $PidFile) {
    $oldPid = (Get-Content $PidFile).Trim()
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Write-Output "Stopping existing status server (PID $oldPid)..."
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
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
        `$ctx  = `$listener.GetContext()
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
    }
} finally { `$listener.Stop() }
"@

$encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($serverScript))

$startArgs = @("-NoProfile", "-EncodedCommand", $encodedCommand)
if ($IsWindows) { $startArgs = @("-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encodedCommand) }

$proc = Start-Process -FilePath "pwsh" -ArgumentList $startArgs -PassThru

Set-Content -Path $PidFile -Value $proc.Id

# --- Display connection info ---
$machineName = (hostname).Trim()
$ip = try {
    ([System.Net.Dns]::GetHostAddresses($machineName) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        Select-Object -First 1).IPAddressToString
} catch { $null }

Write-Output ""
Write-Output "Status server started (PID $($proc.Id), port $Port)."
Write-Output "  Local:  http://localhost:$Port/status/"
if ($ip) {
    Write-Output "  Remote: http://${ip}:$Port/status/"
}
Write-Output "  Host:   http://${machineName}:$Port/status/"
Write-Output ""
Write-Output "Stop with: .\Stop-StatusServer.ps1"
