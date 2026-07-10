<#PSScriptInfo
.VERSION 2026.07.10
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

function Complete-YurunaRun {
    <#
    .SYNOPSIS
        Shared failure-reporting tail for the Set-Resource / Set-Component /
        Set-Workload entrypoints: report the result manifest and exit non-zero on
        failure.
    .DESCRIPTION
        A non-empty result-manifest hashtable coerces to $true, so a bare
        `if (-Not $result)` would silently take the success branch on a failure
        manifest; this tests the `.success` key via Test-YurunaResultManifestOk. On
        failure it writes the compact result JSON and the transcript to the success
        stream (stdout) and exits 1, so bash wrappers using `set -e` observe the
        non-zero process exit instead of marching on with a missing image / failed
        deploy (a failed Publish-*List that printed the transcript but exited 0 would
        surface only later as a `kubectl wait` timeout). On success it writes only a
        Write-Debug pointer to the transcript.

        CALL AS A STATEMENT (not `$x = Complete-YurunaRun`): it streams the report to
        stdout and may terminate the process. $Result is intentionally not
        [Mandatory] so a $null / $false / non-hashtable result still routes through
        Test-YurunaResultManifestOk (which treats all of those as a failure).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reporting tail: emits the manifest/transcript and exits the process. Not a resource mutation; ShouldProcess would not fit an exit-on-failure contract.')]
    param(
        [Parameter(Position = 0)]$Result,
        [Parameter(Position = 1)][string]$TranscriptFile
    )
    if (-Not (Test-YurunaResultManifestOk $Result)) {
        Write-Output ($Result | ConvertTo-Json -Depth 4 -Compress)
        Write-Output $(Get-Content -Path $TranscriptFile)
        exit 1
    }
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $TranscriptFile)"
}

Export-ModuleMember -Function New-YurunaResultManifest, Test-YurunaResultManifestOk, Complete-YurunaRun