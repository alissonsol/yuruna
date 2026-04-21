<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456741
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

<#
.SYNOPSIS
    Stops the status HTTP server started by Start-StatusServer.ps1.

.DESCRIPTION
    Reads the PID from $env:YURUNA_TRACK_DIR/server.pid and terminates
    the process.
#>

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "modules" -AdditionalChildPath "Test.TrackDir.psm1") -Force
$null = Initialize-YurunaTrackDir
$PidFile = Join-Path $env:YURUNA_TRACK_DIR "server.pid"

if (-not (Test-Path $PidFile)) {
    Write-Output "No server PID file found at '$PidFile'. Server may not be running."
    exit 0
}

$pid_value = (Get-Content $PidFile).Trim()
if (-not $pid_value) {
    Write-Output "PID file is empty. Removing it."
    Remove-Item $PidFile -Force
    exit 0
}

$proc = Get-Process -Id $pid_value -ErrorAction SilentlyContinue
if ($proc) {
    Stop-Process -Id $pid_value -Force
    Write-Output "Status server stopped (PID $pid_value)."
} else {
    Write-Output "Process $pid_value is not running. Server was already stopped."
}

Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
