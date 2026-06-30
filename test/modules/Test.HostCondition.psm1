<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42b8c9d0-e1f2-4a34-9567-8f9a0b1c2d31
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host
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

# Cross-platform host-condition facade -- registry-backed dispatcher.
# Per-platform implementations live in Test.HostCondition.{Mac,Windows,
# Linux}.psm1; each contributes a (Set, Assert, AssertMinimum,
# RequiresElevation) record keyed by HostType.
#
# Architecture (facade contract, registry shape, capability matrix):
# https://yuruna.link/test/harness

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Registry anchor; required to survive -Force re-imports of this facade.')]
param()

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

# Backing store is a New-YurunaRegistry bundle anchored under
# $global:YurunaHostConditionProviders so the registrations survive
# -Force re-imports of this facade. Each entry is an [ordered]@{
#   HostType; Set; Assert; AssertMinimum; RequiresElevation
# } record.
$script:HostConditionRegistry = New-YurunaRegistry `
    -Name 'HostCondition' `
    -AnchorVar 'YurunaHostConditionProviders' `
    -Comparer 'OrdinalIgnoreCase'

function Register-HostConditionProvider {
    <#
    .SYNOPSIS
        Bind a (Set, Assert, AssertMinimum, RequiresElevation) record
        to $HostType in the host-condition registry.
    .PARAMETER HostType
        Stable host identifier ('host.windows.hyper-v', 'host.macos.utm',
        'host.ubuntu.kvm', or a future plugin's identifier).
    .PARAMETER Set
        Scriptblock invoked by the operator-facing Enable-TestAutomation
        path. Signature: `param([string]$HostType)`. May mutate host
        state; should honor -WhatIf via its own ShouldProcess.
    .PARAMETER Assert
        Scriptblock invoked by Assert-HostConditionSet at runtime.
        Signature: `param([string]$HostType)`. Must return [bool]
        and emit Write-Warning / Write-Error for any failed condition.
    .PARAMETER AssertMinimum
        Scriptblock invoked by Test-HostRequirement for one-off
        operator helpers (Remove-TestVMFiles.ps1 etc.). Lighter than
        Assert -- the screen-lock / TCC checks belong in Assert, not
        here, because they false-positive during interactive
        maintenance. Signature: `param()`. Returns [bool].
    .PARAMETER RequiresElevation
        Set $true when the host needs Administrator / root for the
        runtime cycle (Hyper-V cmdlets fail with permission denied
        otherwise). Test-ElevationRequired reads this.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Parameters are stored in the registry, not used by this function body.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][scriptblock]$Set,
        [Parameter(Mandatory)][scriptblock]$Assert,
        [Parameter(Mandatory)][scriptblock]$AssertMinimum,
        [bool]$RequiresElevation = $false,
        # Optional per-cycle display-surface ensure (e.g. attach a virtual
        # monitor on a headless Hyper-V host so screen-capture/OCR keeps
        # working). Signature: `param()`, returns a status string. $null
        # for hosts that need nothing (macOS/Linux). Invoked by
        # Initialize-HostDisplay; see docs/host-hyperv.md.
        [scriptblock]$Display = $null,
        # Optional inverse of $Display: tear the surface down when the host
        # stops running tests (e.g. disable the virtual display so a stale
        # one doesn't hang around). Signature: `param()`, returns a status
        # string. $null for hosts that need nothing. Invoked by
        # Remove-HostDisplay from Remove-TestVMFiles.
        [scriptblock]$DisplayTeardown = $null
    )
    & $script:HostConditionRegistry.Register $HostType ([ordered]@{
        HostType          = $HostType
        Set               = $Set
        Assert            = $Assert
        AssertMinimum     = $AssertMinimum
        RequiresElevation = $RequiresElevation
        Display           = $Display
        DisplayTeardown   = $DisplayTeardown
    })
}

function Get-HostConditionProvider {
    <#
    .SYNOPSIS
        Look up the provider record for $HostType. Returns the record
        or $null when no provider is registered.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$HostType)
    return (& $script:HostConditionRegistry.Get $HostType)
}

function Get-HostConditionProviderMatrix {
    <#
    .SYNOPSIS
        Snapshot of every registered provider keyed by HostType. Used by
        the startup capability matrix to render coverage.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return (& $script:HostConditionRegistry.GetMatrix)
}

function Clear-HostConditionProvider {
    <#
    .SYNOPSIS
        Drop every registered host-condition provider.
    .DESCRIPTION
        Tests-only: production code relies on -Force re-import to
        refresh registrations.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.HostCondition registry', 'Clear all providers')) {
        & $script:HostConditionRegistry.Clear
    }
}

# Per-platform siblings. -Global so their exports stay reachable to
# callers that imported only this facade. Import order is immaterial:
# self-registration (Register-IfAvailable, below) resolves each
# platform's functions from the already-populated global session after
# all three siblings have loaded, so no sibling depends on another
# being imported first.
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1')     -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Windows.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Linux.psm1')   -Global -Force -DisableNameChecking

# Self-register each platform by looking up its functions in the global
# session. Missing functions (a stripped-down install where one
# platform module was deleted) cause Register-IfAvailable to skip
# silently; the dispatcher then surfaces an "Unknown host type"
# warning rather than failing on a torn registration.
function script:Register-IfAvailable {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Helper drives Register-HostConditionProvider; the wrapper carries ShouldProcess-equivalent intent at module load.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$SetFn,
        [Parameter(Mandatory)][string]$AssertFn,
        [Parameter(Mandatory)][string]$MinimumFn,
        [bool]$RequiresElevation,
        # Optional: name of a per-cycle display-surface ensure function.
        # Resolved only when present; absent on hosts that need nothing.
        [string]$DisplayFn,
        # Optional: name of the inverse teardown function for the display
        # surface. Resolved only when present; absent on hosts that need nothing.
        [string]$TeardownFn
    )
    $missing = @()
    foreach ($fn in @($SetFn, $AssertFn, $MinimumFn)) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { $missing += $fn }
    }
    if ($missing.Count -gt 0) {
        Write-Verbose "Test.HostCondition: skipping $HostType registration; missing functions: $($missing -join ', ')"
        return
    }
    $displayBlock = $null
    if ($DisplayFn) {
        $displayCmd = Get-Command -Name $DisplayFn -ErrorAction SilentlyContinue
        if ($displayCmd) { $displayBlock = $displayCmd.ScriptBlock }
        else { Write-Verbose "Test.HostCondition: $HostType display ensure '$DisplayFn' not found; skipping that capability." }
    }
    $teardownBlock = $null
    if ($TeardownFn) {
        $teardownCmd = Get-Command -Name $TeardownFn -ErrorAction SilentlyContinue
        if ($teardownCmd) { $teardownBlock = $teardownCmd.ScriptBlock }
        else { Write-Verbose "Test.HostCondition: $HostType display teardown '$TeardownFn' not found; skipping that capability." }
    }
    Register-HostConditionProvider -HostType $HostType `
        -Set             (Get-Command $SetFn).ScriptBlock `
        -Assert          (Get-Command $AssertFn).ScriptBlock `
        -AssertMinimum   (Get-Command $MinimumFn).ScriptBlock `
        -RequiresElevation $RequiresElevation `
        -Display         $displayBlock `
        -DisplayTeardown $teardownBlock
}
Register-IfAvailable -HostType 'host.windows.hyper-v' `
    -SetFn 'Set-WindowsHostConditionSet' -AssertFn 'Assert-WindowsHostConditionSet' -MinimumFn 'Test-WindowsHostMinimum' `
    -DisplayFn 'Install-YurunaVirtualDisplay' -TeardownFn 'Remove-YurunaVirtualDisplay' `
    -RequiresElevation $true
Register-IfAvailable -HostType 'host.macos.utm' `
    -SetFn 'Set-MacHostConditionSet'     -AssertFn 'Assert-MacHostConditionSet'     -MinimumFn 'Test-MacHostMinimum' `
    -RequiresElevation $false
Register-IfAvailable -HostType 'host.ubuntu.kvm' `
    -SetFn 'Set-LinuxHostConditionSet'   -AssertFn 'Assert-LinuxHostConditionSet'   -MinimumFn 'Test-LinuxHostMinimum' `
    -RequiresElevation $false

function Assert-HostConditionSet {
    <#
    .SYNOPSIS
        Platform dispatcher: looks up the registered Assert callback
        for $HostType and invokes it. Returns $true when no provider
        is registered (operator can run on an unknown host without a
        hard failure; the runner's per-step gates still apply).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HostType)
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider) {
        Write-Warning "Unknown host type '$HostType' -- skipping condition checks."
        return $true
    }
    return [bool](& $provider.Assert -HostType $HostType)
}

function Initialize-HostDisplay {
    <#
    .SYNOPSIS
        Platform dispatcher: ensure the host has a usable display surface for
        screen-capture / OCR before a cycle (e.g. attach a virtual display on
        a headless Hyper-V host so DWM keeps painting the synthetic GPU).
    .DESCRIPTION
        Idempotent and cheap to call every cycle: the underlying ensure
        short-circuits when the surface is already present. No-op when the
        provider registers no Display callback (macOS/Linux, or an unknown
        host). Never throws -- a display-ensure failure must not abort the
        cycle; it degrades to the manual-workaround path (see
        docs/host-hyperv.md) and is surfaced as a warning.
    #>
    [CmdletBinding()]
    param([string]$HostType)
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider -or -not $provider.Display) { return }
    try {
        $status = & $provider.Display
        switch ("$status") {
            'Activated'     { Write-Information "Virtual display attached for '$HostType' -- screen-capture is decoupled from the physical monitor." }
            'AlreadyActive' { Write-Verbose "Virtual display already active for '$HostType'." }
            'Failed'        { Write-Warning "Could not ensure a virtual display for '$HostType'; headless screen-capture/OCR may fail. See docs/host-hyperv.md." }
            'Disabled'      { Write-Verbose "Virtual display disabled for '$HostType' (YURUNA_VIRTUAL_DISPLAY not set to true)." }
            default         { Write-Verbose "Initialize-HostDisplay ('$HostType'): $status" }
        }
    } catch {
        Write-Warning "Initialize-HostDisplay ('$HostType') failed: $($_.Exception.Message)"
    }
}

function Remove-HostDisplay {
    <#
    .SYNOPSIS
        Platform dispatcher and inverse of Initialize-HostDisplay: tear down the
        display surface a machine no longer needs once it stops running tests
        (e.g. disable the usbmmidd virtual display on a Hyper-V host so a
        stale/duplicate monitor left by a mid-cycle KVM switch does not linger).
    .DESCRIPTION
        Idempotent and safe to call even when no surface was ever attached: the
        underlying teardown short-circuits when the driver was never staged or no
        virtual display is present. No-op when the provider registers no
        DisplayTeardown callback (macOS/Linux, or an unknown host). Never throws
        -- a teardown failure during cleanup must not abort the caller; it
        degrades to a warning. Invoked by Remove-TestVMFiles.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$HostType)
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider -or -not $provider.DisplayTeardown) { return }
    if (-not $PSCmdlet.ShouldProcess("$HostType display surface", 'Tear down virtual display')) { return }
    try {
        $status = & $provider.DisplayTeardown
        switch ("$status") {
            'Removed'       { Write-Information "Virtual display removed for '$HostType'." }
            'AlreadyAbsent' { Write-Verbose "No virtual display to remove for '$HostType'." }
            'Failed'        { Write-Warning "Could not fully remove the virtual display for '$HostType'. See docs/host-hyperv.md." }
            default         { Write-Verbose "Remove-HostDisplay ('$HostType'): $status" }
        }
    } catch {
        Write-Warning "Remove-HostDisplay ('$HostType') failed: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function `
    Register-HostConditionProvider, Get-HostConditionProvider, Get-HostConditionProviderMatrix, Clear-HostConditionProvider, `
    Assert-HostConditionSet, Initialize-HostDisplay, Remove-HostDisplay, `
    Assert-ScreenLock, Initialize-SudoCache, `
    Set-MacHostConditionSet, Assert-Accessibility, Assert-ScreenRecording, Assert-MacHostConditionSet, Test-MacHostMinimum, `
    Set-WindowsHostConditionSet, Assert-WindowsHostConditionSet, Test-WindowsHostMinimum, `
    Set-LinuxHostConditionSet, Assert-LinuxHostConditionSet, Test-LinuxHostMinimum
