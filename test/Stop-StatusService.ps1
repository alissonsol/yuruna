<#PSScriptInfo
.VERSION 2026.07.03
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
    the process.
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

$proc = Get-Process -Id $pid_value -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Output "Process $pid_value is not running. Server was already stopped."
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
$identityOk = $false
try {
    $pidFileMtime = (Get-Item -LiteralPath $PidFile).LastWriteTime
    $identityOk = ($proc.StartTime -le $pidFileMtime.AddSeconds(2))
} catch {
    Write-Verbose "Identity check failed for PID $pid_value : $($_.Exception.Message)"
}
if ($identityOk) {
    Stop-Process -Id $pid_value -Force
    Write-Output "Status server stopped (PID $pid_value)."
} else {
    Write-Warning "PID $pid_value is not the status server (start time post-dates the PID file, or is unreadable) -- likely recycled after a crash/reboot. Removing the stale PID file without killing it."
}
Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
