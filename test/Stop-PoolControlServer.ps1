<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42f6a7b8-c9d0-4e12-8345-6a7b8c9d0e1f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool control extension service
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
    Stop the host-side Pool control service and clear its marker.
.DESCRIPTION
    Reads runtime/pool-control.json for the pid, stops the process, removes the
    marker (so Test.Capability drops the pool-control area), and refreshes the
    registration record. The Go service posts an active:false beacon goodbye on
    SIGTERM/exit, so the aggregator's Extension-hosts row clears from both paths.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$null        = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ExitOk      = Get-EntryPointExitCode -Outcome Ok

$runtimeDir = if (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue) { Initialize-YurunaRuntimeDir } else { $env:YURUNA_RUNTIME_DIR }
$marker = Join-Path $runtimeDir 'pool-control.json'
if (Test-Path -LiteralPath $marker) {
    try {
        $m = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json -ErrorAction Stop
        if ($m.pid -and $PSCmdlet.ShouldProcess("pid $($m.pid)", 'Stop pool-control')) {
            Stop-Process -Id ([int]$m.pid) -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Verbose "stop pool-control: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
}
if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
    try { Write-HostRegistrationRecord -HostType (Get-HostType) | Out-Null } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }
}
Write-Information 'Pool control stopped; marker cleared.' -InformationAction Continue
exit $ExitOk
