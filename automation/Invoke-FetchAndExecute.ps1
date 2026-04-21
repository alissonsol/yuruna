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

# Cache-busting via environment variables, in priority order:
#   1. EXEC_QUERY_PARAMS  — explicit override, used verbatim (include '?').
#   2. YurunaCacheContent — systemwide cache-buster (unique string, usually a
#      timestamp). Leave unset so caching proxies serve stored copies; set it
#      to force a fresh fetch:
#          $env:YurunaCacheContent = (Get-Date -Format yyyyMMddHHmmss)
#          setx YurunaCacheContent (Get-Date -Format yyyyMMddHHmmss)    # persist
# Both unset/empty → empty suffix, URL stays cacheable.
$BaseUrl = $env:EXEC_BASE_URL ?? "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/"
$NoCache = if ([string]::IsNullOrEmpty($env:YurunaCacheContent)) { '' } else { "?nocache=$($env:YurunaCacheContent)" }
$QueryParams = $env:EXEC_QUERY_PARAMS ?? $NoCache

$FullUrl = "${BaseUrl}${FilePath}${QueryParams}"
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")
Invoke-DynamicExpression -Command (Invoke-RestMethod -Uri $FullUrl)

# End tag — mirrors fetch-and-execute.sh so OCR/keystroke harness matches
Write-Output "`n    FETCHED AND EXECUTED:`n    $FilePath`n"