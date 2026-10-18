<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42370011-0231-4e74-92a9-2c8cee1d8a15
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool storage replication drain
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

# See https://yuruna.link/4213a0b3-0012

[CmdletBinding()]
param([string]$HostId = '')

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath

# --- REGION: Fresh-process module imports
# Fresh-process imports: no -Force needed, so the global-module-eviction trap does
# not apply here. The auth extension is loaded via Import-Extension so the
# operator-configured active module is used (not a hardcoded default.psm1).
foreach ($m in @('Test.PoolStorage.psm1', 'Test.StateFile.psm1', 'Test.Config.psm1', 'Test.YurunaDir.psm1', 'Test.HostIdentity.psm1', 'Test.Log.psm1', 'Test.Extension.psm1')) {
    $p = Join-Path $here $m
    if (Test-Path -LiteralPath $p) { Import-Module $p -Global -ErrorAction SilentlyContinue }
}
if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
    try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
}

# --- REGION: Runtime + log dir gate
$runtimeDir = $env:YURUNA_RUNTIME_DIR
$logDir     = $env:YURUNA_LOG_DIR
if ([string]::IsNullOrWhiteSpace($runtimeDir) -or [string]::IsNullOrWhiteSpace($logDir)) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3990610f59f48a37')
    return
}

# --- REGION: Host identity
if ([string]::IsNullOrWhiteSpace($HostId) -and (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
    try { $HostId = [string](Get-YurunaHostId) } catch { $null = $_ }
}
if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = 'unknown-host' }
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null }

# --- REGION: Run the worker
try {
    if (Get-Command Invoke-PoolStorageDrain -ErrorAction SilentlyContinue) {
        # Resolve the mode from config so a hand-run honors what the host is
        # configured for. The orchestrator owns the single-instance lock, so nothing
        # here has to (and a lock taken out here would deadlock against it).
        $moveLogs = $false
        try {
            $modeCfg = Get-YurunaPoolStorageConfig
            if ($modeCfg) { $moveLogs = [bool]$modeCfg.MoveLogs }
        } catch { Write-Verbose "poolStorage drain: mode resolution failed: $($_.Exception.Message)" }
        $summary = Invoke-PoolStorageDrain -HostId $HostId -LogDir $logDir -RuntimeDir $runtimeDir `
            -MoveLogs:$moveLogs -SpaceCheck:$moveLogs -Confirm:$false
        if ($summary) {
            $tail = if ($moveLogs) { " moved=$($summary.moved) deleted=$($summary.deleted) spaceShort=$($summary.spaceShort)" } else { '' }
            Write-Information ((Format-YurunaOperatorMessage -Key 'runner.operator_4f22b6f3e5bff59b' -Arguments @{ connectOk = "$($summary.connectOk)"; copied = "$($summary.copied)"; pending = "$($summary.pending)"; tail = "$tail"; error = "$($summary.error)" })) -InformationAction Continue
        }
    }
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_458625e945938fdf' -Arguments @{ message = "$($_.Exception.Message)" })
}
