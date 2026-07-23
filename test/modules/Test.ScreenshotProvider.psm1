<#PSScriptInfo
.VERSION 2026.07.22
.GUID 429eb9ac-a948-4c0b-b4f9-fc1974431076
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

# Screenshot-capture provider registry. Same shape as
# Test.HostIO and Test.OcrEngine: per-host capture implementations
# register, and Wait-ForText / saveDebugScreenshot dispatch through
# Invoke-ScreenshotProvider. The legacy Yuruna.Host\Get-VMScreenshot
# contract still works -- this registry is the seam for adding a
# fast-path capturer (e.g., a delta-only frame grabber) or a fallback
# (e.g., when WMI / virsh screenshot times out).
#
# --- REGION: https://yuruna.link/host-io#why-the-registry-uses-a-global-anchor
# Storage: shared Test.Registry primitive; the $global:YurunaScreenshotProviders
# anchor keeps registrations eviction-safe across -Force re-imports.
# The paired self-healing primitive is Repair-ScreenshotRing (see its help).

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

$script:Reg = New-YurunaRegistry -Name 'ScreenshotProvider' -AnchorVar 'YurunaScreenshotProviders' -Comparer 'OrdinalIgnoreCase'

function Register-ScreenshotProvider {
    <#
    .SYNOPSIS
        Register a screenshot capturer scriptblock for $HostType.
    .DESCRIPTION
        Stores the Capturer in the cross-module-eviction-safe global
        registry so Invoke-ScreenshotProvider can dispatch by HostType
        without re-importing Test.Transport's per-host backend.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][scriptblock]$Capturer
    )
    & $script:Reg.Register $HostType $Capturer
}

function Test-ScreenshotProviderAvailable {
    <#
    .SYNOPSIS
        Returns $true when a screenshot provider is registered for $HostType.
    .DESCRIPTION
        Lets the startup capability matrix flag a gap before Wait-ForText
        falls back to Get-VMScreenshot's legacy contract for a host that
        has no fast-path capturer wired in.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    return [bool](& $script:Reg.Has $HostType)
}

function Invoke-ScreenshotProvider {
    <#
    .SYNOPSIS
        Dispatch a screenshot capture to the registered provider for
        $HostType. Throws when unregistered; callers fall back to
        Get-VMScreenshot (the legacy contract).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][hashtable]$Arguments
    )
    if (-not (& $script:Reg.Has $HostType)) {
        throw "Screenshot provider not registered for '$HostType'."
    }
    return [bool](& (& $script:Reg.Get $HostType) $Arguments)
}

function Get-ScreenshotProviderMatrix {
    <#
    .SYNOPSIS
        Snapshot of registered screenshot providers as an ordered
        dictionary keyed by host type.
    .DESCRIPTION
        Used by the startup capability matrix to render which hosts
        have a fast-path screenshot capturer wired in.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $out = [ordered]@{}
    foreach ($h in (& $script:Reg.GetMatrix).Keys) { $out[$h] = $true }
    return $out
}

function Repair-ScreenshotRing {
    <#
    .SYNOPSIS
        Self-healing primitive: clear the in-memory screenshot ring
        buffer for a given VM so the next Wait-ForText poll starts
        fresh against the live framebuffer.
    .DESCRIPTION
        Called from a Handler's catch block when OCR returns no
        detectable text for N consecutive polls. The ring lives under
        $env:YURUNA_LOG_DIR/screen-<VMName>/. Best-effort: missing
        directory or in-flight write is logged Verbose and returns
        $true so the caller's retry can proceed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $ringDir = Join-Path $env:YURUNA_LOG_DIR "screen-$VMName"
    if (-not (Test-Path -LiteralPath $ringDir)) { return $true }
    if (-not $PSCmdlet.ShouldProcess($ringDir, 'Clear screenshot ring buffer')) { return $true }
    try {
        Get-ChildItem -LiteralPath $ringDir -Filter '*.png' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Verbose "Repair-ScreenshotRing: $($_.Exception.Message)"
        return $false
    }
}

function Clear-ScreenshotProvider {
    <#
    .SYNOPSIS
        Drop every registered screenshot provider.
    .DESCRIPTION
        Tests-only: production code relies on -Force re-import to
        refresh registrations. The primitive's Clear rebinds the backing
        store AND updates the global anchor so the registry is observably
        empty.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.ScreenshotProvider registry', 'Clear all providers')) {
        & $script:Reg.Clear
    }
}

Export-ModuleMember -Function Register-ScreenshotProvider, Test-ScreenshotProviderAvailable, Invoke-ScreenshotProvider, Get-ScreenshotProviderMatrix, Repair-ScreenshotRing, Clear-ScreenshotProvider
