<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456780
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

function Get-YurunaLogDir {
    <#
    .SYNOPSIS
        Returns the global YurunaLog directory path, creating it if needed.
    #>
    $tempRoot = $env:TEMP ?? $env:TMPDIR ?? '/tmp'
    $logDir = Join-Path $tempRoot 'YurunaLog'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return $logDir
}

Export-ModuleMember -Function Get-YurunaLogDir
