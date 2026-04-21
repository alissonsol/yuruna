<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456781
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

function Initialize-YurunaTrackDir {
    <#
    .SYNOPSIS
        Ensure $env:YURUNA_TRACK_DIR points to a writable tracking directory,
        creating the directory if needed. Idempotent.
    .DESCRIPTION
        $env:YURUNA_TRACK_DIR holds runtime tracking artifacts that are
        small and operationally interesting: status.json, *.pid files,
        control.*-pause flags, ipaddresses.txt, caching-proxy.txt, server.err,
        and the detached status-server script. Keeping these separate from
        $env:YURUNA_LOG_DIR (which contains bulky HTML transcripts and OCR
        debug artifacts) makes investigations faster — you don't sift
        through hundreds of log files to find the current runner.pid.

        Default location is <testRoot>/status/track/ so the status HTTP
        server can serve the files at /track/<name>. Callers can override
        by setting $env:YURUNA_TRACK_DIR before import; the status server
        then maps /track/* onto the overridden path.
    .OUTPUTS
        System.String. The resolved $env:YURUNA_TRACK_DIR path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_TRACK_DIR) {
        # <testRoot>/status/track/ — this module lives at test/modules/
        # so two levels up is test/.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $env:YURUNA_TRACK_DIR = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'track'
    }
    if (-not (Test-Path $env:YURUNA_TRACK_DIR)) {
        New-Item -ItemType Directory -Path $env:YURUNA_TRACK_DIR -Force | Out-Null
    }
    return $env:YURUNA_TRACK_DIR
}

Export-ModuleMember -Function Initialize-YurunaTrackDir
