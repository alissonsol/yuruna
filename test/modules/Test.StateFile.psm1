<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42e9f8a7-b6c5-4d34-9281-3e4f5a6b7c93
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna state-file atomic-write sidecar
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
    Atomic write primitive for Yuruna state sidecars (pidfiles, JSON
    sidecars, runtime markers).
.DESCRIPTION
    Single source of truth for the temp-file + rename pattern used by
    every Yuruna state sidecar. Design notes (concurrent-reader
    guarantees, per-writer unique temp naming, boot-recovery contract)
    live at https://yuruna.link/state-sidecar.
#>

function Write-YurunaStateFile {
    <#
    .SYNOPSIS
        Atomic temp-file + rename writer for a string payload.
    .PARAMETER Path
        Destination path. Parent directory MUST already exist.
    .PARAMETER Content
        String payload to write.
    .PARAMETER WithBom
        Write UTF-8 with BOM. Default is UTF-8 without BOM (matches
        what JSON / YAML / shell consumers expect; the BOM trips most
        non-PowerShell parsers).
    .OUTPUTS
        [bool] $true on success, $false when temp write or rename fails.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'ShouldProcess wraps the actual write below; attribute is on the function.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$WithBom
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Atomic state-file write')) { return $true }
    $encoding = if ($WithBom) {
        [System.Text.UTF8Encoding]::new($true)
    } else {
        [System.Text.UTF8Encoding]::new($false)
    }
    # Per-writer unique temp name. See https://yuruna.link/state-sidecar
    # for why a fixed "$Path.tmp" is unsafe under concurrent writers.
    $tmp = "$Path.$PID-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, $encoding)
    } catch {
        Write-Verbose "Write-YurunaStateFile: tmp write at $tmp failed: $($_.Exception.Message)"
        return $false
    }
    try {
        # [File]::Move with overwrite=$true is an atomic MoveFileEx/ReplaceFile on Windows;
        # Move-Item -Force is delete-then-rename, so a concurrent reader can catch the gap
        # where the destination briefly does not exist.
        [System.IO.File]::Move($tmp, $Path, $true)
    } catch {
        Write-Verbose "Write-YurunaStateFile: rename $tmp -> $Path failed: $($_.Exception.Message)"
        # Best-effort clean-up of the orphan .tmp so a future run isn't
        # surprised by a stale partial write sharing the directory.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    return $true
}

function Write-YurunaStateFileJson {
    <#
    .SYNOPSIS
        Convenience wrapper that serializes -InputObject to JSON via
        ConvertTo-Json + delegates to Write-YurunaStateFile.
    .PARAMETER Path
        Destination JSON file path.
    .PARAMETER InputObject
        Anything ConvertTo-Json accepts (typically a hashtable).
    .PARAMETER Depth
        ConvertTo-Json depth. Default 10 gives headroom over the deepest
        current sidecar. Objects nested deeper than -Depth serialize as
        "@{...}" strings with NO error (the silent JSON depth-truncation
        trap class), so keep this ahead of the payload's real nesting.
    .PARAMETER Compress
        Emit single-line JSON (default; matches the format on-wire
        consumers expect). Pass -Compress:$false for pretty-printed
        output during local debugging.
    .PARAMETER WithBom
        Write UTF-8 with a BOM. Default is no BOM (what JSON consumers
        expect). Pass-through to Write-YurunaStateFile for the rare reader
        that needs one.
    .OUTPUTS
        [bool] $true on success, $false on serialization or write failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Delegates to Write-YurunaStateFile which gates with ShouldProcess.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject,
        [int]$Depth = 10,
        [bool]$Compress = $true,
        [switch]$WithBom
    )
    $json = $null
    try {
        if ($Compress) {
            $json = $InputObject | ConvertTo-Json -Compress -Depth $Depth
        } else {
            $json = $InputObject | ConvertTo-Json -Depth $Depth
        }
    } catch {
        Write-Verbose "Write-YurunaStateFileJson: ConvertTo-Json failed for $Path : $($_.Exception.Message)"
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Atomic JSON state-file write')) { return $true }
    return (Write-YurunaStateFile -Path $Path -Content $json -WithBom:$WithBom -Confirm:$false)
}

Export-ModuleMember -Function Write-YurunaStateFile, Write-YurunaStateFileJson
