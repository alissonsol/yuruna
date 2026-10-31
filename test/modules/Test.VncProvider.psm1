<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42c24ab4-c6de-46b2-84f3-6852dccf9a66
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# VNC connection provider registry + recovery primitive. See
# ../../docs/host-io.md#backends-today for the caching/recovery design. -- Test.VncProvider.psm1
#
# --- REGION: https://yuruna.link/4222e5f2-0009
# Storage: shared Test.Registry primitive; the $global:YurunaVncProviders
# anchor keeps registrations eviction-safe across -Force re-imports.

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
        afterward (for cleanup of platform-specific state -- e.g., a
        Windows port forward or an AppleScript window-focus reset).

        The handle carries keystrokes only; no screenshot path reads it, so
        dropping it cannot revive a capture feed. A caller that hopes it
        did judges by a later frame, never by this result.
    .OUTPUTS
        [pscustomobject] Attempted (something was reset), Effective (the reset
        completed: the cache was cleared, or the host provider reported
        success) and Mechanism ('vnc-input-handle', 'host-provider' or 'none').
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$HostType
    )
    $outcome = { param([bool]$Attempted, [bool]$Effective, [string]$Mechanism) [pscustomobject]@{ Attempted = $Attempted; Effective = $Effective; Mechanism = $Mechanism } }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'runner.operator_1cbf528eda6cfdb7'))) { return (& $outcome $false $false 'none') }
    $mechanism = 'none'
    $effective = $false
    if (Get-Command Disconnect-VNC -ErrorAction SilentlyContinue) {
        $mechanism = 'vnc-input-handle'
        try { Disconnect-VNC -VMName $VMName; $effective = $true } catch { Write-Verbose "Disconnect-VNC threw: $($_.Exception.Message)" }
    }
    if ($HostType -and (& $script:Reg.Has $HostType)) {
        try {
            return (& $outcome $true ([bool](& (& $script:Reg.Get $HostType) $VMName)) 'host-provider')
        } catch {
            $vncErr = $_
            Write-Verbose "VNC reconnect threw: $($vncErr.Exception.Message)"
            # Structured failure signal so a remediator routes on
            # `event=vnc_reconnect_failed` (instead of regex-parsing a
            # Verbose line that gets stripped at log level Information).
            # Best-effort: a caller that never loaded Test.Log must still get
            # the $false below, not a command-not-found thrown from this catch.
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event        = 'vnc_reconnect_failed'
                    vmName       = [string]$VMName
                    hostType     = [string]$HostType
                    error        = $vncErr.Exception.Message
                    failureClass = 'host_io_blocked'
                    severity     = 'soft'
                }
            }
            return (& $outcome $true $false 'host-provider')
        }
    }
    return (& $outcome ($mechanism -ne 'none') $effective $mechanism)
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
    if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_eb9b3983cb632707'), (Format-YurunaOperatorMessage -Key 'runner.operator_01286d1a561aca1c'))) {
        & $script:Reg.Clear
    }
}

Export-ModuleMember -Function Register-VncProvider, Test-VncProviderAvailable, Get-VncProviderMatrix, Repair-VncConnection, Clear-VncProvider
