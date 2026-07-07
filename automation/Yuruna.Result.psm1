<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42f6c5d4-e3b2-4a0b-7890-1c2d3e4f5a62
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Result
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

# --- REGION: https://yuruna.link/memory#why-the-yuruna-result-manifest-is-shaped-this-way

function New-YurunaResultManifest {
    <#
    .SYNOPSIS
        Build a Yuruna result manifest hashtable.
    .DESCRIPTION
        Pure builder for the canonical result manifest shape (success,
        skipped, errorMessage, failureClass, exitCode, durationMs,
        artifacts). All keys default so callers may set only what they
        know; the rest carry the documented neutral values.
    .OUTPUTS
        [hashtable] with the canonical result-manifest keys populated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a hashtable. Does not touch disk, processes, or any external state.')]
    param(
        [Parameter()][bool]$Success = $true,
        [Parameter()][bool]$Skipped = $false,
        [Parameter()][string]$ErrorMessage = '',
        [Parameter()][ValidateSet('ok','config_error','cluster_unreachable','chart_invalid','tool_failed','unknown')]
        [string]$FailureClass = 'ok',
        [Parameter()][int]$ExitCode = 0,
        [Parameter()][long]$DurationMs = 0,
        [Parameter()][hashtable[]]$Artifacts = @()
    )
    return @{
        success      = $Success
        skipped      = $Skipped
        errorMessage = $ErrorMessage
        failureClass = $FailureClass
        exitCode     = $ExitCode
        durationMs   = $DurationMs
        artifacts    = $Artifacts
    }
}

function Test-YurunaResultManifestOk {
    <#
    .SYNOPSIS
        Convenience boolean test on a manifest's `success` key.
    .DESCRIPTION
        Callers that just want pass/fail can write
            if (Test-YurunaResultManifestOk $result) { ... }
        instead of
            if ($result.success) { ... }
        A $null manifest, a manifest missing the `success` key, or a
        manifest whose `success` is not $true returns $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        $Manifest
    )
    if ($null -eq $Manifest) { return $false }
    if ($Manifest -isnot [hashtable] -and $Manifest -isnot [System.Collections.IDictionary]) { return $false }
    if (-not $Manifest.Contains('success')) { return $false }
    return [bool]$Manifest['success']
}

Export-ModuleMember -Function New-YurunaResultManifest, Test-YurunaResultManifestOk