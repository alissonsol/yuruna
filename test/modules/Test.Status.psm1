<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456702
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

$script:Doc  = $null
$script:File = $null

# Initialises a fresh status document for a new run and writes status.json.
# Returns the runId string.
function Initialize-StatusDocument {
    param(
        [string]   $StatusFilePath,
        [string]   $HostType,
        [string]   $Hostname,
        [string]   $GitCommit,
        [string[]] $GuestList
    )
    $script:File = $StatusFilePath

    $history = @()
    if (Test-Path $StatusFilePath) {
        try {
            $prev = Get-Content -Raw $StatusFilePath | ConvertFrom-Json
            if ($prev.history) { $history = @($prev.history) }
        } catch { }
    }

    $runId = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")

    $guests = foreach ($key in $GuestList) {
        [ordered]@{
            guestKey = $key
            vmName   = $null
            status   = "pending"
            steps    = @(
                [ordered]@{ name="GetImage";  status="pending"; startedAt=$null; finishedAt=$null; skipped=$false; errorMessage=$null }
                [ordered]@{ name="NewVM";     status="pending"; startedAt=$null; finishedAt=$null; skipped=$false; errorMessage=$null }
                [ordered]@{ name="VerifyVM";  status="pending"; startedAt=$null; finishedAt=$null; skipped=$false; errorMessage=$null }
                [ordered]@{ name="CleanupVM"; status="pending"; startedAt=$null; finishedAt=$null; skipped=$false; errorMessage=$null }
            )
        }
    }

    $script:Doc = [ordered]@{
        schemaVersion = 1
        host          = $HostType
        hostname      = $Hostname
        runId         = $runId
        startedAt     = $runId
        finishedAt    = $null
        overallStatus = "running"
        gitCommit     = $GitCommit
        guests        = @($guests)
        history       = $history
    }

    Write-StatusJson
    return $runId
}

# Sets the vmName field for a guest in the current document.
function Set-GuestVMName {
    param([string]$GuestKey, [string]$VMName)
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if ($g) { $g.vmName = $VMName }
}

# Updates the top-level status of a guest and flushes status.json.
function Set-GuestStatus {
    param([string]$GuestKey, [string]$Status)
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if ($g) { $g.status = $Status }
    Write-StatusJson
}

# Updates a step inside a guest and flushes status.json.
function Set-StepStatus {
    param(
        [string] $GuestKey,
        [string] $StepName,
        [string] $Status,
        [bool]   $Skipped      = $false,
        [string] $ErrorMessage = $null
    )
    $g = $script:Doc.guests | Where-Object { $_.guestKey -eq $GuestKey }
    if (-not $g) { return }
    $step = $g.steps | Where-Object { $_.name -eq $StepName }
    if (-not $step) { return }

    $now = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    if ($Status -eq "running") {
        $step.startedAt = $now
    } else {
        if (-not $step.startedAt) { $step.startedAt = $now }
        $step.finishedAt = $now
    }
    $step.status  = $Status
    $step.skipped = $Skipped
    if ($ErrorMessage) { $step.errorMessage = $ErrorMessage }
    Write-StatusJson
}

# Marks the run as finished, appends to history, and flushes status.json.
function Complete-Run {
    param([string]$OverallStatus, [int]$MaxHistoryRuns = 30)
    $script:Doc.finishedAt    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    $script:Doc.overallStatus = $OverallStatus

    $guestSummary = @{}
    foreach ($g in $script:Doc.guests) { $guestSummary[$g.guestKey] = $g.status }

    $entry = [ordered]@{
        runId         = $script:Doc.runId
        startedAt     = $script:Doc.startedAt
        finishedAt    = $script:Doc.finishedAt
        overallStatus = $OverallStatus
        gitCommit     = $script:Doc.gitCommit
        host          = $script:Doc.host
        guestSummary  = $guestSummary
    }
    $script:Doc.history = @($entry) + @($script:Doc.history) | Select-Object -First $MaxHistoryRuns
    Write-StatusJson
}

# Atomically writes the in-memory document to status.json.
function Write-StatusJson {
    $tmp = "$($script:File).tmp"
    $script:Doc | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $script:File -Force
}

# Starts a background HTTP server serving the status/ directory.
# Returns the background job object.
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

Export-ModuleMember -Function Initialize-StatusDocument, Set-GuestVMName, Set-GuestStatus, Set-StepStatus, Complete-Run, Write-StatusJson, Start-StatusServer, Stop-StatusServer
