<#PSScriptInfo
.VERSION 2026.11.05
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
    Stop the config service started by Start-ConfigService.ps1.
.DESCRIPTION
    Reads the PID from $env:YURUNA_RUNTIME_DIR/config-server.pid and terminates
    the detached serve process.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
# Nothing below changes anything unless the stop is confirmed.
if (-not $PSCmdlet.ShouldProcess('config service', 'Stop the config service')) { return }

# --- REGION: Initialize service runtime
# See https://yuruna.link/42fffc2c-000b
# See https://yuruna.link/42162449-0004
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules" -AdditionalChildPath "Test.YurunaDir.psm1") -Force
$null = Initialize-YurunaRuntimeDir
$PidFile = Join-Path $env:YURUNA_RUNTIME_DIR "config-server.pid"

Stop-YurunaPidFileService -PidFile $PidFile -ServiceName 'config service' -Confirm:$false
