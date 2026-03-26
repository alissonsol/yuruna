<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456710
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

# Starts a background HTTP server that serves the status/ directory.
# Uses System.Net.HttpListener inside a PowerShell background job.
# Returns the job object so the caller can stop it later.
function Start-StatusServer {
    param([string]$StatusDir, [int]$Port = 8080)
    $prefix = "http://localhost:$Port/"
    $job = Start-Job -ScriptBlock {
        param($dir, $pfx)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($pfx)
        try {
            $listener.Start()
            while ($listener.IsListening) {
                $ctx  = $listener.GetContext()
                $req  = $ctx.Request
                $res  = $ctx.Response
                $path = $req.Url.LocalPath.TrimStart('/')
                if ($path -eq '' -or $path -eq 'status/' -or $path -eq 'status') { $path = 'index.html' }
                $path = $path -replace '^status[/\\]?', ''
                $file = Join-Path $dir $path
                if (Test-Path $file -PathType Leaf) {
                    $ext = [System.IO.Path]::GetExtension($file)
                    $res.ContentType = switch ($ext) {
                        '.html' { 'text/html; charset=utf-8' }
                        '.json' { 'application/json; charset=utf-8' }
                        '.css'  { 'text/css; charset=utf-8' }
                        '.js'   { 'application/javascript; charset=utf-8' }
                        default { 'application/octet-stream' }
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
    } -ArgumentList $StatusDir, $prefix
    Write-Information "Status page: ${prefix}status/" -InformationAction Continue
    return $job
}

# Stops the background HTTP server job.
function Stop-StatusServer {
    param($Job)
    if ($Job) {
        Stop-Job   -Job $Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Start-StatusServer, Stop-StatusServer
