<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42f9c4d6-8a2b-4e73-9d51-7c3e4f5a6b72
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
    Stops the Host Config Service started by Start-HostConfigService.ps1.

.DESCRIPTION
    Reads the PID from $env:YURUNA_RUNTIME_DIR/config-server.pid and terminates
    the detached serve process.
#>

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "modules" -AdditionalChildPath "Test.YurunaDir.psm1") -Force
$null = Initialize-YurunaRuntimeDir
$PidFile = Join-Path $env:YURUNA_RUNTIME_DIR "config-server.pid"

if (-not (Test-Path $PidFile)) {
    Write-Output "No config-server PID file found at '$PidFile'. Service may not be running."
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
    Write-Output "Host Config Service stopped (PID $pid_value)."
} else {
    Write-Output "Process $pid_value is not running. Service was already stopped."
}

Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
