<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42805144-34fe-4c3d-8d6b-916357d3b102
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner diagnostic preservation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

# --- REGION: Get-DiagnosticVmPreservation
function Get-DiagnosticVmPreservation {
    <#
    .SYNOPSIS
        Read the durable failed-VM hold without treating a corrupt marker as release.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
    $path = Join-Path $RuntimeDir 'diagnostic-preserve.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $entry = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($entry -isnot [IO.FileInfo] -or $entry.LinkType -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (-not $IsWindows -and $entry.UnixMode -notmatch '^-')) { throw 'Nonregular preservation marker.' }
        if ($entry.Length -gt 65536) { throw 'Oversized preservation marker.' }
        $record = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($record.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$record.vmName)) { throw 'Invalid preservation marker.' }
        return $record
    } catch {
        return @{ schemaVersion=1; state='invalid'; vmName=''; reason='unreadable-preservation-marker' }
    }
}

# --- REGION: Set-DiagnosticVmPreservation
function Set-DiagnosticVmPreservation {
    <#
    .SYNOPSIS
        Persist a failed VM hold before diagnostic capture can throw or hang.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VMName,
        [string]$GuestKey,
        [string]$StepName,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $false }
    $path = Join-Path $RuntimeDir 'diagnostic-preserve.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'Preserve failed VM for diagnostic inspection')) { return $false }
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $null = [IO.Directory]::CreateDirectory($RuntimeDir)
        $record = [ordered]@{
            schemaVersion = 1
            state = 'held'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            vmName = $VMName
            guestKey = $GuestKey
            stepName = $StepName
            reason = 'stopOnFailure'
            release = 'Remove diagnostic-preserve.json or set testCycle.stopOnFailure to false.'
        }
        [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
        return $true
    } catch {
        Write-Verbose "Unable to persist diagnostic preservation marker: $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

# --- REGION: Wait-DiagnosticVmPreservation
function Wait-DiagnosticVmPreservation {
    <#
    .SYNOPSIS
        Park the runner before recovery or VM cleanup until the operator releases evidence.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Consumes the operator release decision; no VM or host setting is changed.')]
    param(
        [Parameter(Mandatory)][hashtable]$ShutdownState,
        [string]$ConfigPath,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [switch]$HoldOnFailure
    )
    if (-not (Get-DiagnosticVmPreservation -RuntimeDir $RuntimeDir)) {
        if ($HoldOnFailure -and $ConfigPath -and (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
            try {
                $failedConfig = Read-TestConfig -Path $ConfigPath -ErrorAction Stop
                if ($failedConfig.testCycle.stopOnFailure -is [bool] -and $failedConfig.testCycle.stopOnFailure) {
                    if (-not (Set-DiagnosticVmPreservation -VMName '(unknown)' -RuntimeDir $RuntimeDir -Confirm:$false)) {
                        $ShutdownState['Requested'] = $true
                        return 'shutdown'
                    }
                }
            } catch { Write-Verbose 'Unable to resolve failure preservation configuration.' }
        }
        if (-not (Get-DiagnosticVmPreservation -RuntimeDir $RuntimeDir)) { return 'absent' }
    }
    $path = Join-Path $RuntimeDir 'diagnostic-preserve.json'
    try {
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $current = if (Get-Command Get-RunnerState -ErrorAction SilentlyContinue) { [string](Get-RunnerState).current } else { '' }
            if ($current -eq 'cycle-end') {
                $null = Set-RunnerState -To 'idle' -Reason 'Diagnostic preservation boundary' -Confirm:$false
                $current = 'idle'
            }
            if ($current -ne 'paused') {
                if ($current -ne 'fault') { $null = Set-RunnerState -To 'fault' -Reason 'Diagnostic VM preserved for inspection' -Confirm:$false }
                $null = Set-RunnerState -To 'paused' -Reason 'Diagnostic VM preserved for inspection' -Confirm:$false
            }
        }
        if (Get-Command Update-RunnerFaultStatus -ErrorAction SilentlyContinue) {
            $null = Update-RunnerFaultStatus -RuntimeDir $RuntimeDir -RunnerState 'paused' `
                -Reason 'Diagnostic VM preserved for inspection' -FailureClass 'unknown' -Confirm:$false
        }
    } catch { Write-Verbose 'Diagnostic preservation remains active while status publication is unavailable.' }
    $nextConfigRead = [DateTime]::MinValue
    try {
      while (Test-Path -LiteralPath $path) {
        if ($ShutdownState['Requested']) { return 'shutdown' }
        if ([DateTime]::UtcNow -ge $nextConfigRead) {
            $nextConfigRead = [DateTime]::UtcNow.AddSeconds(2)
            try {
                if ($ConfigPath -and (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                    $config = Read-TestConfig -Path $ConfigPath -ErrorAction Stop
                    $cycleConfig = $config.testCycle
                    if ($cycleConfig -is [Collections.IDictionary] -and $cycleConfig.Contains('stopOnFailure') -and
                        $cycleConfig['stopOnFailure'] -is [bool] -and -not $cycleConfig['stopOnFailure']) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                        return 'released'
                    }
                }
            } catch {
                Write-Verbose 'Diagnostic preservation remains active while configuration is unavailable.'
            }
        }
        Start-Sleep -Milliseconds 250
      }
      return 'released'
    } finally {
        if (-not (Test-Path -LiteralPath $path)) {
            try {
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'idle' -Reason 'Diagnostic preservation released' -Confirm:$false
                }
            } catch { Write-Verbose 'Diagnostic preservation was released while status publication was unavailable.' }
        }
    }
}

Export-ModuleMember -Function Get-DiagnosticVmPreservation, Set-DiagnosticVmPreservation, Wait-DiagnosticVmPreservation
