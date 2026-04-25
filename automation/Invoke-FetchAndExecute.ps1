<#PSScriptInfo
.VERSION 0.1
.GUID 42c3d4e5-f6a7-4b89-0c1d-2e3f4a5b6c7d
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS Invoke-FetchAndExecute
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

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FilePath
)

# Base URL resolution (priority order — mirrors fetch-and-execute.sh):
#   1. $env:EXEC_BASE_URL — explicit override, used verbatim.
#   2. /etc/yuruna/host.env — written by New-VM.ps1 at provision time.
#      Probe /livecheck; on success the host status server wins over
#      GitHub. On failure or missing file, fall through.
#   3. https://raw.githubusercontent.com/... — final fallback.
#
# Cache-busting (in priority order):
#   1. $env:EXEC_QUERY_PARAMS — explicit override, used verbatim (include '?').
#   2. YurunaCacheContent — systemwide cache-buster (unique string, usually a
#      timestamp). Leave unset so caching proxies serve stored copies; set it
#      to force a fresh fetch:
#          $env:YurunaCacheContent = (Get-Date -Format yyyyMMddHHmmss)
#          setx YurunaCacheContent (Get-Date -Format yyyyMMddHHmmss)    # persist
# Both unset/empty → empty suffix, URL stays cacheable.
function Resolve-BaseUrl {
    if (-not [string]::IsNullOrEmpty($env:EXEC_BASE_URL)) {
        return @{ Url = $env:EXEC_BASE_URL; Source = 'override' }
    }
    $hostEnv = '/etc/yuruna/host.env'
    if (Test-Path $hostEnv) {
        $hostIp = $null; $hostPort = $null
        foreach ($line in Get-Content $hostEnv) {
            $entry = $line.Trim()
            if ($entry -match '^YURUNA_HOST_IP=(.*)$')   { $hostIp   = $Matches[1].Trim() }
            if ($entry -match '^YURUNA_HOST_PORT=(.*)$') { $hostPort = $Matches[1].Trim() }
        }
        if ($hostIp -and $hostPort) {
            try {
                $null = Invoke-WebRequest -Uri "http://${hostIp}:${hostPort}/livecheck" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                return @{ Url = "http://${hostIp}:${hostPort}/yuruna-repo/"; Source = 'host' }
            } catch {
                Write-Verbose "yuruna-host probe failed: $($_.Exception.Message)"
            }
        }
    }
    return @{ Url = 'https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/'; Source = 'github' }
}
$resolved = Resolve-BaseUrl
$BaseUrl = $resolved.Url
$BaseSource = $resolved.Source
$NoCache = if ([string]::IsNullOrEmpty($env:YurunaCacheContent)) { '' } else { "?nocache=$($env:YurunaCacheContent)" }
$QueryParams = $env:EXEC_QUERY_PARAMS ?? $NoCache

$FullUrl = "${BaseUrl}${FilePath}${QueryParams}"
Write-Output "fetch-and-execute: $FilePath"
Write-Output "  url: $FullUrl"
Write-Output "  source: $BaseSource"
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")
Invoke-DynamicExpression -Command (Invoke-RestMethod -Uri $FullUrl)

# End tag — mirrors fetch-and-execute.sh so OCR/keystroke harness matches
Write-Output "`n    FETCHED AND EXECUTED:`n    $FilePath`n"