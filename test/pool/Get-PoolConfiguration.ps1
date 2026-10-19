<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 421c914b-b896-456f-9955-33d362db4fd8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Emit the pool configuration (pools and the auto-enrollment policy) as JSON. Read-only.
.DESCRIPTION
    Backs the pool-control service UI's data reads. Clones/pulls the configuration store and
    writes a single JSON object to stdout: { ok, pools:[...], autoEnrollment:{...} }
    (the pools and the autoEnrollment block from pools.yml). The pools come
    through Read-YurunaPoolsDoc, so a store still at an older schemaVersion is
    shown in the schemaVersion 4 shape (`configuredState` and `repositories`) before it is
    migrated. Never writes the store. On any error, emits { ok:false, error:"..." }
    and exits non-zero so the caller can surface it.
.EXAMPLE
    ./Get-PoolConfiguration.ps1 -ConfigurationGitUrl /var/lib/yuruna/pool-configuration.git
#>

[CmdletBinding()]
param(
    [string]$ConfigurationGitUrl,
    [string]$ConfigurationDir
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ModulesDir  = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
Import-Module powershell-yaml -ErrorAction Stop

# --- REGION: Write-JsonResult
function Write-JsonResult { param($Obj) [Console]::Out.WriteLine(($Obj | ConvertTo-Json -Depth 12 -Compress)) }

try {
    # --- REGION: Open the configuration store
    $open = Open-YurunaPoolAdminStore -ConfigurationGitUrl $ConfigurationGitUrl -ConfigurationDir $ConfigurationDir -Confirm:$false
    $t = $open.Target
    if (-not $open.Ok) { Write-JsonResult ([ordered]@{ ok = $false; error = $open.Error }); exit $ExitFailure }
    # --- REGION: Report
    $doc = Read-YurunaPoolsDoc -ConfigurationDir $t.ConfigurationDir
    # See https://yuruna.link/42010605-0004
    $autoEnrollment = if ($doc -is [System.Collections.IDictionary] -and $doc['autoEnrollment']) { $doc['autoEnrollment'] } else { [ordered]@{} }
    Write-JsonResult ([ordered]@{ ok = $true; pools = @($doc['pools']); autoEnrollment = $autoEnrollment })
    exit $ExitOk
} catch {
    Write-JsonResult ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit $ExitFailure
}
