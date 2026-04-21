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

function Initialize-YurunaLogDir {
    <#
    .SYNOPSIS
        Ensure $env:YURUNA_LOG_DIR points to a writable log directory,
        creating the directory if needed. Idempotent.
    .DESCRIPTION
        $env:YURUNA_LOG_DIR is the unified reference for Yuruna's log
        folder across scripts and modules. If unset, defaults to
        <TEMP>/YurunaLog. Callers should reference $env:YURUNA_LOG_DIR
        directly after invoking this initializer at least once.
    .OUTPUTS
        System.String. The resolved $env:YURUNA_LOG_DIR path, for the
        common case where a caller wants it inline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_LOG_DIR) {
        $tempRoot = $env:TEMP ?? $env:TMPDIR ?? '/tmp'
        $env:YURUNA_LOG_DIR = Join-Path $tempRoot 'YurunaLog'
    }
    if (-not (Test-Path $env:YURUNA_LOG_DIR)) {
        New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
    }
    return $env:YURUNA_LOG_DIR
}

Export-ModuleMember -Function Initialize-YurunaLogDir
