<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4224a01c-42f9-40b1-9d8a-f42012e52f84
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
    Stops the config service started by Start-ConfigService.ps1.

.DESCRIPTION
    Reads the PID from $env:YURUNA_RUNTIME_DIR/config-server.pid and terminates
    the detached serve process.
#>

Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules" -AdditionalChildPath "Test.YurunaDir.psm1") -Force
$null = Initialize-YurunaRuntimeDir
$PidFile = Join-Path $env:YURUNA_RUNTIME_DIR "config-server.pid"

Stop-YurunaPidFileService -PidFile $PidFile -ServiceName 'config service' -Confirm:$false
