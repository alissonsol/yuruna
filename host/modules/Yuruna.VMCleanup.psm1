<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42b8c9d0-e1f2-4a34-9567-89b0c1d2e3f4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host orphaned-vm cleanup
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
    Shared helpers for the per-platform Remove-OrphanedVMFiles.ps1 scripts.
.DESCRIPTION
    The three platform scripts ([host/windows.hyper-v/Remove-OrphanedVMFiles.ps1](../windows.hyper-v/Remove-OrphanedVMFiles.ps1),
    [host/macos.utm/Remove-OrphanedVMFiles.ps1](../macos.utm/Remove-OrphanedVMFiles.ps1),
    [host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1](../ubuntu.kvm/Remove-OrphanedVMFiles.ps1))
    need the same Write-Status routing function and (on Hyper-V + UTM)
    the same base-image-name discovery loop. All three route -Quiet
    through Set-VMCleanupQuiet here so the quiet contract stays in one
    place; the scripts never touch the module-internal $script:QuietOutput
    flag directly. Both helpers live here so the routing + naming stay in
    lockstep.
#>

$script:QuietOutput = $false

function Set-VMCleanupQuiet {
    <#
    .SYNOPSIS
        Toggle the module-wide quiet flag.
    .DESCRIPTION
        The cleanup scripts route their progress chatter through
        Write-CleanupMessage. When the operator passes -Quiet (or when
        Remove-TestVMFiles.ps1 calls the script with -Quiet for an
        unattended sweep), messages drop to Write-Verbose so the host
        log stays clean while diagnostics survive on -Verbose.
        Warnings + errors are untouched -- those always represent an
        actual problem the operator must see.
    .PARAMETER Quiet
        $true to route Write-CleanupMessage to Write-Verbose;
        $false to route it to Write-Output (the default).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'ShouldProcess gates the actual write to module state; this attribute is for the wrapper.')]
    param(
        [bool]$Quiet = $false
    )
    if ($PSCmdlet.ShouldProcess('Yuruna.VMCleanup quiet state', "Set to $Quiet")) {
        $script:QuietOutput = $Quiet
    }
}

function Write-CleanupMessage {
    <#
    .SYNOPSIS
        Route an operator-facing progress line through Write-Output or
        Write-Verbose depending on the module-wide quiet flag.
    .PARAMETER Message
        The line to surface. Pipeline-bound so the scripts can stream
        multi-line banners without a foreach loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)][string]$Message
    )
    process {
        if ($script:QuietOutput) { Write-Verbose $Message } else { Write-Output $Message }
    }
}

function Resolve-BaseImageName {
    <#
    .SYNOPSIS
        Discover the base-image filenames the host's Get-Image.ps1 scripts
        write under host/&lt;short&gt;/guest.&lt;name&gt;/.
    .DESCRIPTION
        Base images follow the convention `host.&lt;short&gt;.guest.&lt;name&gt;`
        (e.g. `host.windows.hyper-v.guest.amazon.linux.2023`). The cleanup
        scripts need the full name list so the orphan check skips them
        even when no VM currently references them. KVM doesn't use this
        -- its base images live outside the per-VM tree -- so this helper
        is only called by the Hyper-V and UTM scripts.
    .PARAMETER HostScriptDir
        Absolute path to the directory holding the Remove-OrphanedVMFiles.ps1
        script (e.g. `c:\git\yuruna\host\windows.hyper-v`). The leaf becomes
        `&lt;short&gt;`; subdirectories matching `guest.*` enumerate the guests.
    .OUTPUTS
        [hashtable] @{ HostFolder = 'host.&lt;short&gt;'; BaseImageNames = @(...) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$HostScriptDir
    )
    $hostFolder = "host.$(Split-Path -Leaf $HostScriptDir)"
    $names      = New-Object System.Collections.Generic.List[string]
    $guestDirs  = Get-ChildItem -LiteralPath $HostScriptDir -Directory -Filter 'guest.*' -ErrorAction SilentlyContinue
    foreach ($g in $guestDirs) {
        $names.Add("$hostFolder.$($g.Name)")
    }
    return @{ HostFolder = $hostFolder; BaseImageNames = $names.ToArray() }
}

Export-ModuleMember -Function Set-VMCleanupQuiet, Write-CleanupMessage, Resolve-BaseImageName
