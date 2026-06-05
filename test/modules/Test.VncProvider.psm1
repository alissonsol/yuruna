<#PSScriptInfo
.VERSION 2026.06.05
.GUID 4295730e-1cff-47df-b4d6-b3fd3578c818
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

# VNC connection provider registry + recovery primitive, second of four paired registry+recovery modules.
#
# Today Test.Transport caches a single VNC handle ($script:CachedVnc,
# $script:CachedVncVM) and reuses it across steps. The cache is fast
# (saves ~200 ms per Send-Key VNC call on macOS UTM) but BRITTLE: a
# guest reboot, network partition, or VNC server restart leaves the
# handle in a closed state, and the next Send-TextVNC silently drops
# every keystroke until the cache is invalidated.
#
# This registry's recovery primitive Repair-VncConnection forces the
# next call to re-handshake. Invoked from Wait-ForText's bounded no-text
# self-heal (several consecutive polls with no OCR text is a likely sign
# the cached handle is feeding frozen frames) and available to any
# host_io_blocked recovery path.
#
# Storage is delegated to the shared Test.Registry primitive
# (New-YurunaRegistry) so there is one registry mechanism across the
# harness and this domain shows up in the cross-domain introspection
# directory (Get-YurunaRegistryDirectory/Summary). The
# $global:YurunaVncProviders anchor name is reused as the backing store
# so registrations stay cross-module-eviction-safe and survive -Force
# re-imports.

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

$script:Reg = New-YurunaRegistry -Name 'VncProvider' -AnchorVar 'YurunaVncProviders' -Comparer 'OrdinalIgnoreCase'

function Register-VncProvider {
    <#
    .SYNOPSIS
        Register a host-specific VNC reconnect scriptblock.
    .DESCRIPTION
        Stores the Reconnect scriptblock in the cross-module-eviction-
        safe global registry so Repair-VncConnection can run platform-
        specific reconnect logic (e.g. resetting a Windows port forward
        or an AppleScript window-focus state) after Disconnect-VNC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][scriptblock]$Reconnect
    )
    & $script:Reg.Register $HostType $Reconnect
}

function Test-VncProviderAvailable {
    <#
    .SYNOPSIS
        Returns $true when a VNC reconnect provider is registered for
        $HostType.
    .DESCRIPTION
        Used by the startup capability matrix to flag a gap before
        Repair-VncConnection falls back to the bare Disconnect-VNC path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    return [bool](& $script:Reg.Has $HostType)
}

function Get-VncProviderMatrix {
    <#
    .SYNOPSIS
        Snapshot of registered VNC providers as an ordered dictionary
        keyed by host type.
    .DESCRIPTION
        Used by the startup capability matrix to render which hosts
        have a registered VNC reconnect scriptblock.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $out = [ordered]@{}
    foreach ($h in (& $script:Reg.GetMatrix).Keys) { $out[$h] = $true }
    return $out
}

function Repair-VncConnection {
    <#
    .SYNOPSIS
        Drop the cached VNC handle in Test.Transport so the next
        Send-Key/Send-Text/Send-Click VNC call re-handshakes.
    .DESCRIPTION
        Called when a keystroke-send appears to succeed (no error
        thrown) but no character lands in the guest framebuffer.
        Test.Transport caches the connection in $script:CachedVnc /
        $script:CachedVncVM; this primitive clears those globals via
        the corresponding Disconnect-VNC contract function exported by
        Test.Transport. If a per-host provider is registered, it runs
        afterward (for cleanup of platform-specific state -- e.g, a
        Windows port forward or an AppleScript window-focus reset).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$HostType
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Repair-VncConnection (clear cached handle, force re-handshake)')) { return $true }
    if (Get-Command Disconnect-VNC -ErrorAction SilentlyContinue) {
        try { Disconnect-VNC -VMName $VMName } catch { Write-Verbose "Disconnect-VNC threw: $($_.Exception.Message)" }
    }
    if ($HostType -and (& $script:Reg.Has $HostType)) {
        try {
            return [bool](& (& $script:Reg.Get $HostType) $VMName)
        } catch {
            $vncErr = $_
            Write-Verbose "VNC reconnect threw: $($vncErr.Exception.Message)"
            # Structured failure signal so a remediator routes on
            # `event=vnc_reconnect_failed` (instead of regex-parsing a
            # Verbose line that gets stripped at log level Information).
            Send-CycleEventSafely -EventRecord @{
                timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event        = 'vnc_reconnect_failed'
                vmName       = [string]$VMName
                hostType     = [string]$HostType
                error        = $vncErr.Exception.Message
                failureClass = 'host_io_blocked'
                severity     = 'soft'
            }
            return $false
        }
    }
    return $true
}

function Clear-VncProvider {
    <#
    .SYNOPSIS
        Drop every registered VNC provider.
    .DESCRIPTION
        Tests-only: production code relies on -Force re-import to
        refresh registrations. The primitive's Clear rebinds the backing
        store AND updates the global anchor so the registry is observably
        empty.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.VncProvider registry', 'Clear all providers')) {
        & $script:Reg.Clear
    }
}

Export-ModuleMember -Function Register-VncProvider, Test-VncProviderAvailable, Get-VncProviderMatrix, Repair-VncConnection, Clear-VncProvider
