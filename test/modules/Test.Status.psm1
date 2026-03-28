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
# $StepNames controls which steps are tracked per guest (allows the caller
# to add "CustomTests" when extension scripts are present).
# Returns the runId string.
function Initialize-StatusDocument {
    param(
        [string]   $StatusFilePath,
        [string]   $HostType,
        [string]   $Hostname,
        [string]   $GitCommit,
        [string[]] $GuestList,
        [string[]] $StepNames = @("New-VM", "Start-VM", "Verify-VM")
    )
    $script:File = $StatusFilePath

    $history = @()
    $lastGetImageAt = $null
    $cycle = 0
    if (Test-Path $StatusFilePath) {
        try {
            $prev = Get-Content -Raw $StatusFilePath | ConvertFrom-Json
            if ($prev.history) { $history = @($prev.history) }
            if ($prev.lastGetImageAt) { $lastGetImageAt = $prev.lastGetImageAt }
            if ($prev.cycle) { $cycle = [int]$prev.cycle }
        } catch { }
    }

    $runId = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")

    $guests = foreach ($key in $GuestList) {
        $steps = foreach ($sn in $StepNames) {
            [ordered]@{ name=$sn; status="pending"; startedAt=$null; finishedAt=$null; skipped=$false; errorMessage=$null }
        }
        [ordered]@{
            guestKey = $key
            vmName   = $null
            status   = "pending"
            steps    = @($steps)
        }
    }

    $script:Doc = [ordered]@{
        schemaVersion  = 1
        host           = $HostType
        hostname       = $Hostname
        runId          = $runId
        startedAt      = $runId
        finishedAt     = $null
        overallStatus  = "running"
        gitCommit      = $GitCommit
        lastGetImageAt = $lastGetImageAt
        cycle          = $cycle + 1
        guests         = @($guests)
        history        = $history
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

# Reads the lastGetImageAt timestamp from the status file.
# Returns $null if not set.
function Get-LastGetImageTime {
    param([string]$StatusFilePath)
    if ($script:Doc -and $script:Doc.lastGetImageAt) {
        return $script:Doc.lastGetImageAt
    }
    if (-not (Test-Path $StatusFilePath)) { return $null }
    try {
        $doc = Get-Content -Raw $StatusFilePath | ConvertFrom-Json
        return $doc.lastGetImageAt
    } catch { return $null }
}

# Records the current time as the last Get-Image timestamp and flushes status.json.
function Set-LastGetImageTime {
    $script:Doc.lastGetImageAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    Write-StatusJson
}

Export-ModuleMember -Function Initialize-StatusDocument, Set-GuestVMName, Set-GuestStatus, Set-StepStatus, Complete-Run, Write-StatusJson, Get-LastGetImageTime, Set-LastGetImageTime
