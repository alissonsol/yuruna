<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456741
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
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
    Stops the status HTTP server started by Start-StatusService.ps1.

.DESCRIPTION
    Reads the PID from $env:YURUNA_RUNTIME_DIR/server.pid and terminates
    the detached serve process.
#>

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "modules" -AdditionalChildPath "Test.YurunaDir.psm1") -Force
$null = Initialize-YurunaRuntimeDir
$PidFile = Join-Path $env:YURUNA_RUNTIME_DIR "server.pid"

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

# Parse the PID before touching Get-Process/Stop-Process: -Id coerces its argument
# to [int] at parameter-binding time, and that ParameterBindingException is NOT
# suppressed by -ErrorAction SilentlyContinue -- a corrupt/non-numeric PID file
# would throw an unhandled error here. Treat an unparseable value as a stale file
# (remove it, no kill), matching the launcher's own [int]::TryParse guard.
$id = 0
if (-not [int]::TryParse($pid_value, [ref]$id)) {
    Write-Output "PID file holds a non-numeric value ('$pid_value'). Removing the stale file."
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$proc = Get-Process -Id $id -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Output "Process $id is not running. Server was already stopped."
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    exit 0
}
# PID-reuse guard: the PID file persists across crashes and reboots and the OS
# recycles PIDs, so confirm this PID is still the status server before force-
# killing it. The server launched and then wrote this PID file, so a genuine
# match started at/before the file's mtime; a process that reused the PID after
# the server died started later. If the start time is unreadable we cannot
# confirm identity, so treat the PID file as stale (remove it, no kill) rather
# than risk force-killing an unrelated process.
if (Test-PidFileIdentity -PidFile $PidFile -Process $proc) {
    Stop-Process -Id $id -Force
    Write-Output "Status server stopped (PID $id)."
} else {
    Write-Warning "PID $id is not the status server (start time post-dates the PID file, wrong process, or unreadable) -- likely recycled after a crash/reboot. Removing the stale PID file without killing it."
}
Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
