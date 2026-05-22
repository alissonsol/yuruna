<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456790
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

# Two cross-module channels are intentionally process-wide: __YurunaLogFile
# (set here, read by the Yuruna.Log proxy) and __YurunaCycleFolder (the
# cycle's folder under test/status/log/, read by failure / diagnostics
# helpers so the path doesn't have to thread through every call site).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'global:__YurunaLogFile is the cross-module log-file handle read by Yuruna.Log.psm1; global:__YurunaCycleFolder is the cycle folder path read by failure / diagnostics handlers; both intentionally process-wide.')]
param()

function Format-CycleFolderBaseName {
<#
.SYNOPSIS
    Builds the cycleFolder base name: "000001.YYYY-MM-DD.HH-mm-ss.HOSTNAME".
.DESCRIPTION
    Single source of truth for the format so Start-LogFile, the per-guest
    folder helper, and the dashboard JS all produce identical strings.
    CycleNumber is zero-padded to 6 digits per spec; CycleId is parsed
    as an ISO-8601 UTC timestamp and split into date + time-with-dashes
    (colons can't appear in filenames on Windows/macOS volumes).
#>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int]$CycleNumber,
        [Parameter(Mandatory)] [string]$CycleId,
        [Parameter(Mandatory)] [string]$Hostname
    )
    $padded = '{0:D6}' -f $CycleNumber
    # CycleId is "2026-05-11T16:24:39Z" -- index 0..9 is the date,
    # index 11..18 is HH:mm:ss. Defensive .Length checks so a caller
    # passing a non-ISO timestamp (Test-Sequence.ps1 one-shots) still
    # yields a usable folder name with whatever the substring produces.
    $cycleDate = if ($CycleId.Length -ge 10) { $CycleId.Substring(0,10) } else { 'unknown-date' }
    $cycleTime = if ($CycleId.Length -ge 19) { ($CycleId.Substring(11,8) -replace ':','-') } else { 'unknown-time' }
    return "$padded.$cycleDate.$cycleTime.$Hostname"
}

function Get-LogDir {
    <#
    .SYNOPSIS
        Returns the test/status/log directory path, creating it if needed.
    #>
    param([string]$TestRoot)
    $logDir = Join-Path -Path $TestRoot -ChildPath "status" -AdditionalChildPath "log"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return $logDir
}

function Start-LogFile {
    <#
    .SYNOPSIS
        Creates this cycle's folder and starts logging Write-* output
        to the HTML file inside it.
    .DESCRIPTION
        Folder layout:
            test/status/log/000001.YYYY-MM-DD.HH-mm-ss.HOSTNAME/
                000001.YYYY-MM-DD.HH-mm-ss.HOSTNAME.html
                <vmName>/        <- created lazily by per-guest helper
                    <date>-<time>.system.diagnostic.<id>.txt
                    raw_*.png/raw_*.txt    (on failure)
                    failure_screenshot.png (on failure)
                    failure_ocr.txt        (on failure)
        Sets:
          $global:__YurunaLogFile      absolute path of the HTML file
          $global:__YurunaCycleFolder  absolute path of the cycle folder
        so the Yuruna.Log proxy module appends to the right file and
        downstream helpers (Copy-FailureArtifactsToStatusLog,
        saveSystemDiagnostic action) can locate per-guest subfolders
        without having to plumb the path through every call site.
    .OUTPUTS
        The absolute path to the HTML log file (existing callers store
        it as $LogFile and pass it around).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TestRoot,
        [Parameter(Mandatory)] [string]$CycleId,
        [Parameter(Mandatory)] [string]$Hostname,
        # Monotonic cycle counter (1, 2, 3, ...). Defaults to 0 for
        # callers without cycle context (Test-Sequence.ps1); the
        # resulting folder is 000000.YYYY-MM-DD.HH-mm-ss.HOSTNAME which
        # is still unique-per-invocation thanks to the timestamp.
        [int]$CycleNumber = 0
    )
    $logDir = Get-LogDir -TestRoot $TestRoot
    $cycleBase = Format-CycleFolderBaseName -CycleNumber $CycleNumber -CycleId $CycleId -Hostname $Hostname
    $cycleFolder = Join-Path $logDir $cycleBase
    $logFile = Join-Path $cycleFolder "$cycleBase.html"
    if ($PSCmdlet.ShouldProcess($logFile, 'Start log file')) {
        if (-not (Test-Path $cycleFolder)) {
            New-Item -ItemType Directory -Path $cycleFolder -Force | Out-Null
        }
        # HTML preamble with cache-control meta tags so the log expires in
        # the browser after 30s and a hard reload always fetches fresh
        # content. Status server already sends
        # `Cache-Control: no-store, no-cache, must-revalidate` as HTTP
        # headers, but browsers still serve stale pages from bfcache
        # (back/forward navigation) and some proxies ignore response
        # headers. Meta tags are advisory but bake the directive into the
        # file itself so it survives download / mirroring / direct
        # file:// opens as well.
        $preamble = @'
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta http-equiv="Cache-Control" content="max-age=30, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<title>Yuruna test-runner log</title>
</head><body><pre>
'@
        $preamble | Microsoft.PowerShell.Utility\Out-File -FilePath $logFile -Encoding utf8 -ErrorAction SilentlyContinue
        $global:__YurunaLogFile = $logFile
        $global:__YurunaCycleFolder = $cycleFolder
        # Fallback: import the proxy module if not already loaded
        if (-not (Get-Module Yuruna.Log)) {
            $repoRoot = Split-Path -Parent (Split-Path -Parent $TestRoot)
            $logModule = Join-Path -Path $repoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
            if (Test-Path $logModule) {
                Import-Module $logModule -Global -Force -Verbose:$false
            }
        }
        # Persist the cycle folder URL on the status doc so the dashboard
        # can build per-guest tile links without re-deriving the format.
        # Soft-import-and-call: Test.Status may not be loaded for callers
        # that drive Start-LogFile directly (Test-Sequence.ps1); in
        # those contexts there's no status doc to update either.
        if (Get-Command Set-CycleFolderUrl -ErrorAction SilentlyContinue) {
            Set-CycleFolderUrl -RelativeUrl "log/$cycleBase/"
        }
    }
    return $logFile
}

function Get-CycleGuestDataFolder {
    <#
    .SYNOPSIS
        Returns the absolute path of the per-guest data folder
        ("cycleGuestDataFolder") under the current cycleFolder, creating
        it on demand.
    .DESCRIPTION
        Layout: {cycleFolder}/{VMName}/. Every file produced for a guest
        within this cycle -- failure screenshots, OCR text, system
        diagnostics, etc. -- is written under this folder so the
        dashboard tile that links here surfaces them all in one place.
        Returns $null when called before Start-LogFile (no cycle folder
        established), so callers can no-op without crashing the cycle.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$VMName
    )
    if (-not $global:__YurunaCycleFolder) { return $null }
    $folder = Join-Path $global:__YurunaCycleFolder $VMName
    if ($PSCmdlet.ShouldProcess($folder, 'Ensure cycleGuestDataFolder exists')) {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }
    return $folder
}

function Get-CycleScreenDir {
    <#
    .SYNOPSIS
        Returns the absolute path of the per-VM Wait-ForText ring-buffer
        directory ({cycleFolder}/screens_{VMName}/), creating it on demand.
    .DESCRIPTION
        Wait-ForText captures every pre-OCR screenshot + its OCR sidecar
        into this directory so the failure path can surface the run-up
        to the bug. Nested INSIDE the cycle folder (not at the
        YURUNA_LOG_DIR root) so a cycle that hangs / restarts with no
        failure-path firing still leaves its evidence behind under the
        cycle that produced it -- the next cycle gets its own folder
        and can't overwrite earlier captures.
        Falls back to {YURUNA_LOG_DIR}/screens_{VMName}/ when no cycle
        folder is established (Test-Sequence.ps1 normally calls
        Start-LogFile, but defensive in case future drivers don't).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaCycleFolder is the cross-module cycle folder handle set by Start-LogFile.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$VMName
    )
    if ($global:__YurunaCycleFolder) {
        $folder = Join-Path $global:__YurunaCycleFolder "screens_${VMName}"
    } else {
        if (-not $env:YURUNA_LOG_DIR) {
            Import-Module (Join-Path $PSScriptRoot 'Test.LogDir.psm1') -Force -ErrorAction SilentlyContinue
            if (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue) {
                Initialize-YurunaLogDir | Out-Null
            }
        }
        $folder = Join-Path $env:YURUNA_LOG_DIR "screens_${VMName}"
    }
    if ($PSCmdlet.ShouldProcess($folder, 'Ensure cycle screen dir exists')) {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }
    return $folder
}

function Stop-LogFile {
    <#
    .SYNOPSIS
        Stops file logging by clearing the log file path.
    .DESCRIPTION
        Clears $global:__YurunaLogFile so the Yuruna.Log proxy stops
        appending to the log file. The proxy module remains loaded so
        it can be reactivated by the next Start-LogFile call.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('log file', 'Stop logging')) {
        if ($global:__YurunaLogFile) {
            "</pre></body></html>" | Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
        }
        $global:__YurunaLogFile = $null
        $global:__YurunaCycleFolder = $null
    }
}

Export-ModuleMember -Function Start-LogFile, Stop-LogFile, Get-CycleGuestDataFolder, Get-CycleScreenDir, Format-CycleFolderBaseName
