<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42a3e685-78ad-4652-bb9e-5eca911727a0
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

Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules" -AdditionalChildPath "Test.YurunaDir.psm1") -Force
$null = Initialize-YurunaRuntimeDir
$PidFile = Join-Path $env:YURUNA_RUNTIME_DIR "server.pid"
# A marker outliving the service it describes is worse than none: it reads as
# authoritative, and a caller sends its whole timeout to an address nothing is
# listening on.
$ServiceMarkerFile = Join-Path $env:YURUNA_RUNTIME_DIR 'status-service.json'
Remove-Item -LiteralPath $ServiceMarkerFile -Force -ErrorAction SilentlyContinue

Stop-YurunaPidFileService -PidFile $PidFile -ServiceName 'status service' -Confirm:$false
