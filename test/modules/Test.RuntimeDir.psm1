<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456781
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

function Initialize-YurunaRuntimeDir {
    <#
    .SYNOPSIS
        Ensure $env:YURUNA_RUNTIME_DIR points to a writable runtime directory,
        creating the directory if needed. Idempotent.
    .DESCRIPTION
        $env:YURUNA_RUNTIME_DIR holds the small operationally-interesting
        state files: status.json, *.pid files, control.*-pause flags,
        ipaddresses.txt, caching-proxy.txt, server.err, host.uuid, and
        the detached status-server script. Keeping these separate from
        $env:YURUNA_LOG_DIR (which contains bulky HTML transcripts and OCR
        debug artifacts) makes investigations faster -- you don't sift
        through hundreds of log files to find the current runner.pid.

        Default location is <testRoot>/status/runtime/ so the status HTTP
        server can serve the files at /runtime/<name>. Callers can override
        by setting $env:YURUNA_RUNTIME_DIR before import; the status server
        then maps /runtime/* onto the overridden path.
    .OUTPUTS
        System.String. The resolved $env:YURUNA_RUNTIME_DIR path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_RUNTIME_DIR) {
        # <testRoot>/status/runtime/ -- this module lives at test/modules/
        # so two levels up is test/.
        $testRoot = Split-Path -Parent $PSScriptRoot
        $env:YURUNA_RUNTIME_DIR = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'runtime'
    }
    if (-not (Test-Path $env:YURUNA_RUNTIME_DIR)) {
        New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force | Out-Null
    }
    return $env:YURUNA_RUNTIME_DIR
}

Export-ModuleMember -Function Initialize-YurunaRuntimeDir
