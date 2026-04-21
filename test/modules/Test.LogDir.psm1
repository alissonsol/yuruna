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
        directory: bulky HTML transcripts, OCR debug images, failure
        screenshots, per-component debug subdirs (NewText, Screenshot).
        Separate from $env:YURUNA_TRACK_DIR, which holds the small
        operationally-interesting state files (pids, status.json,
        control flags). Callers should reference $env:YURUNA_LOG_DIR
        directly after invoking this initializer at least once.
    .OUTPUTS
        System.String. The resolved $env:YURUNA_LOG_DIR path, for the
        common case where a caller wants it inline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_LOG_DIR) {
        # Default: <testRoot>/status/log/. Co-located with the track dir
        # and served by the status HTTP server at /log/<name>, so bulky
        # diagnostic artifacts (HTML transcripts, OCR debug images,
        # failure screenshots) can be linked directly from the status
        # page without copying them out of %TEMP%. Override by setting
        # $env:YURUNA_LOG_DIR before import; the server maps /log/* onto
        # the overridden path.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $env:YURUNA_LOG_DIR = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'log'
    }
    if (-not (Test-Path $env:YURUNA_LOG_DIR)) {
        New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
    }
    return $env:YURUNA_LOG_DIR
}

Export-ModuleMember -Function Initialize-YurunaLogDir
