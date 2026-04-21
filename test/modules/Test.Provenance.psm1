<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456782
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Reads a two-line base-image provenance sidecar written by Get-Image.ps1.
.DESCRIPTION
    Each Get-Image.ps1 writes a companion .txt next to the base image with:
      line 1: the ORIGINAL filename (as downloaded — e.g. ubuntu-24.04.4-desktop-amd64.iso)
      line 2: the source URL the file was fetched from
    These feed two consumers:
      * New-VM.ps1 — emits a Provenance: line (or a warning) right after
        "Creating VM '...' using image: ..." so the transcript carries an
        audit-trail hint about where the ISO came from.
      * Invoke-TestRunner — seeds each guest entry in status.json with
        provenance{Filename,Url}, letting the UI swap the card title from
        the generic "guest.ubuntu.desktop" to the actual ISO filename.
    The sidecar path is computed by swapping the image extension for .txt.
.PARAMETER BaseImagePath
    Full path to the base image (e.g. .iso / .vhdx / .qcow2). The companion
    sidecar path is derived from this by swapping the extension to .txt.
.OUTPUTS
    [hashtable] with fields:
      ProvenancePath (string), FileExists (bool), Filename (string), Url (string)
    Filename/Url are trimmed; absent lines surface as empty strings.
#>
function Get-BaseImageProvenance {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BaseImagePath
    )
    $provenancePath = [System.IO.Path]::ChangeExtension($BaseImagePath, '.txt')
    $result = @{
        ProvenancePath = $provenancePath
        FileExists     = $false
        Filename       = ''
        Url            = ''
    }
    if (Test-Path -LiteralPath $provenancePath) {
        $result.FileExists = $true
        $lines = @(Get-Content -Path $provenancePath -ErrorAction SilentlyContinue)
        if ($lines.Count -ge 1 -and $null -ne $lines[0]) { $result.Filename = "$($lines[0])".Trim() }
        if ($lines.Count -ge 2 -and $null -ne $lines[1]) { $result.Url      = "$($lines[1])".Trim() }
    }
    return $result
}

<#
.SYNOPSIS
    Emits a Provenance: / warning line based on the sidecar at $BaseImagePath.
.DESCRIPTION
    Three observable outcomes, matching the spec:
      * sidecar missing           -> Write-Warning "base image provenance file not present"
      * sidecar present, URL blank-> Write-Warning "base image provenance not present"
      * URL present               -> Write-Output  "Provenance: <url>"
    Intended to be called from each host/guest New-VM.ps1 immediately after
    the "Creating VM '...' using image: ..." line so the audit-trail hint
    appears next to the image reference in the transcript.
#>
function Write-BaseImageProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseImagePath
    )
    $p = Get-BaseImageProvenance -BaseImagePath $BaseImagePath
    if (-not $p.FileExists) {
        Write-Warning "base image provenance file not present"
        return
    }
    if ([string]::IsNullOrWhiteSpace($p.Url)) {
        Write-Warning "base image provenance not present"
        return
    }
    Write-Output "Provenance: $($p.Url)"
}

Export-ModuleMember -Function Get-BaseImageProvenance, Write-BaseImageProvenance
