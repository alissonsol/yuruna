<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456710
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
    Starts a background HTTP server that serves the status/ directory.
.DESCRIPTION
    Binds to all interfaces so remote machines can connect.
    Returns the job object so the caller can stop it later.
    Note: the standalone Start-StatusServer.ps1 script is preferred over
    this module function for production use.
#>
function Start-StatusServer {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$StatusDir, [int]$Port = 8080)
    if (-not $PSCmdlet.ShouldProcess("HTTP listener on port $Port", 'Start')) { return $null }
    $prefix = "http://*:$Port/"
    $statusDirLocal = $StatusDir
    $prefixLocal = $prefix
    $job = Start-Job -ScriptBlock {
        $dir = $using:statusDirLocal
        $pfx = $using:prefixLocal
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($pfx)
        try {
            $listener.Start()
            while ($listener.IsListening) {
                $ctx  = $listener.GetContext()
                $req  = $ctx.Request
                $res  = $ctx.Response

                $res.Headers.Add("Access-Control-Allow-Origin", "*")

                $path = $req.Url.LocalPath.TrimStart('/')
                if ($path -eq '' -or $path -eq 'status/' -or $path -eq 'status') { $path = 'index.html' }
                # Strip the optional status/ directory prefix (require the trailing separator
                # so that /status.json is NOT corrupted into .json)
                $path = $path -replace '^status[/\\]', ''
                $file = Join-Path $dir $path
                if (Test-Path $file -PathType Leaf) {
                    $ext = [System.IO.Path]::GetExtension($file)
                    $res.ContentType = switch ($ext) {
                        '.html' { 'text/html; charset=utf-8' }
                        '.json' { 'application/json; charset=utf-8' }
                        '.css'  { 'text/css; charset=utf-8' }
                        '.js'   { 'application/javascript; charset=utf-8' }
                        '.txt'  { 'text/plain; charset=utf-8' }
                        default { 'application/octet-stream' }
                    }
                    if ($ext -eq '.json') {
                        $res.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")
                        $res.Headers.Add("Pragma", "no-cache")
                    }
                    $bytes = [System.IO.File]::ReadAllBytes($file)
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $res.StatusCode = 404
                    $body = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                    $res.OutputStream.Write($body, 0, $body.Length)
                }
                $res.OutputStream.Close()
            }
        } finally { $listener.Stop() }
    }

    # Resolve the machine's hostname and IP for display
    $machineName = (hostname).Trim()
    $ip = try {
        ([System.Net.Dns]::GetHostAddresses($machineName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1).IPAddressToString
    } catch { $null }

    Write-Information "" -InformationAction Continue
    Write-Information "Status page (local):  http://localhost:$Port/status/" -InformationAction Continue
    if ($ip) {
        Write-Information "Status page (remote): http://${ip}:$Port/status/" -InformationAction Continue
    }
    Write-Information "Status page (host):   http://${machineName}:$Port/status/" -InformationAction Continue
    Write-Information "" -InformationAction Continue
    return $job
}

<#
.SYNOPSIS
    Stops the background HTTP server job.
#>
function Stop-StatusServer {
    [CmdletBinding(SupportsShouldProcess)]
    param($Job)
    if ($Job -and $PSCmdlet.ShouldProcess("Status server job $($Job.Id)", 'Stop')) {
        Stop-Job   -Job $Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Start-StatusServer, Stop-StatusServer
