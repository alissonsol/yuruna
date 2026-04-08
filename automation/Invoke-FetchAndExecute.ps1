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

# Configuration with environment overrides
$BaseUrl = $env:EXEC_BASE_URL ?? "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/"
$QueryParams = $env:EXEC_QUERY_PARAMS ?? "?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

# Construct and execute
$FullUrl = "${BaseUrl}${FilePath}${QueryParams}"
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")
Invoke-DynamicExpression -Command (Invoke-RestMethod -Uri $FullUrl)

# End tag
Write-Output "`n    FETCHED AND EXECUTED:`n    $FilePath)`n"