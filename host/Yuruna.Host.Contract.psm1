<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42c4b1e7-5a8d-4f23-9b1c-7e3f8a2d4c61
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host contract
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
    Canonical Yuruna.Host driver contract.
.DESCRIPTION
    Every per-host driver (host/<host>/modules/Yuruna.Host.psm1) MUST
    export every name in $script:YurunaHostContract below. Host-specific
    extras (UTM bundle utilities, Hyper-V firewall helpers, KVM external-
    network planners, etc.) remain in the driver's Export-ModuleMember
    list alongside the canonical block.

    The contract is enforced at module-load time via
    Assert-YurunaHostContractCoverage. A driver that omits a canonical
    verb logs a single warning naming every missing name -- a drift
    caught at load is zero-cost; a drift caught mid-cycle on a remote
    host costs an overnight run.

    Rationale lives in docs/host-io.md and docs/capability-matrix.md;
    this file is the executable source of truth.

    Naming policy (by design):
        The contract uses generic verbs -- New-VM, Start-VM, Stop-VM,
        Remove-VM -- that happen to collide with the Hyper-V module's
        cmdlet names. This is intentional. Hyper-V is one of three
        virtualization backends Yuruna supports (UTM, libvirt/KVM, and
        Hyper-V); a contract named for any one backend would mis-frame
        the abstraction. The per-host driver modules live under
        host/<host>/modules/ and are imported into the runner's session
        with -Global only when that host is selected, so the collision
        is scoped to the runner runspace -- the drivers are NOT on
        PSModulePath and won't shadow Hyper-V cmdlets in other shells.
        Callers that need the Hyper-V cmdlet explicitly inside a Yuruna
        sequence use module-qualified `Hyper-V\Start-VM`; the unqualified
        `Start-VM` always resolves to the active host's driver contract.
#>

# Verb names a Yuruna host driver is expected to export. Adding a verb
# here is a contract-widening event: every driver must implement it
# before the new verb is consumed by the orchestrator. Removing one is
# a deprecation event: confirm no caller references it before pulling.
$script:YurunaHostContract = @(
    # VM lifecycle
    'New-VM', 'Start-VM', 'Stop-VM', 'Stop-VMForce', 'Remove-VM',
    'Rename-VM', 'Get-VMState',
    # Disk snapshots
    'Save-VMDiskSnapshot', 'Restore-VMDiskSnapshot', 'Test-VMDiskSnapshot',
    # VM console
    'Test-VMConsoleOpen', 'Restart-VMConsole',
    # Image acquisition
    'Get-Image', 'Get-ImagePath',
    # Input + capture
    'Send-Text', 'Send-Key', 'Send-Click',
    'Get-VMScreenshot', 'Get-VMConsoleHandle',
    # Guest networking probes
    'Wait-VMIp', 'Get-VMIp', 'Get-VMMac',
    # External / shared network
    'Get-ExternalNetwork', 'New-ExternalNetwork', 'Test-CacheVMOnExternalNetwork',
    # Host port mapping
    'Add-PortMap', 'Remove-PortMap',
    'Get-BestHostIp', 'Get-GuestReachableHostIp',
    # Caching proxy probes
    'Test-CachingProxyAvailable', 'Get-CachingProxyVMIp',
    # Host proxy management
    'Set-HostProxy', 'Clear-HostProxy', 'Remove-HostProxy',
    'Get-HostProxyBackupPath', 'Assert-Virtualization'
)

function Get-YurunaHostContractVerb {
    <#
    .SYNOPSIS
        Canonical verb names every host driver must export.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return ,$script:YurunaHostContract
}

function Assert-YurunaHostContractCoverage {
    <#
    .SYNOPSIS
        Verifies that the supplied function list covers the canonical
        Yuruna.Host contract.
    .DESCRIPTION
        Each per-host Yuruna.Host.psm1 calls this once at module load,
        passing the same list it hands to Export-ModuleMember. Missing
        names are reported in a single Write-Warning naming every gap
        so the operator sees the full delta in one line. Returns $true
        when coverage is complete, $false otherwise -- callers can fail
        loudly or continue based on policy.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExportedFunction
    )
    $exported = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$ExportedFunction, [System.StringComparer]::OrdinalIgnoreCase)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:YurunaHostContract) {
        if (-not $exported.Contains($name)) { [void]$missing.Add($name) }
    }
    if ($missing.Count -gt 0) {
        Write-Warning "Yuruna.Host driver '$HostType' is missing $($missing.Count) contract verb(s): $($missing -join ', '). See host/Yuruna.Host.Contract.psm1."
        return $false
    }
    Write-Verbose "Yuruna.Host driver '$HostType' covers all $($script:YurunaHostContract.Count) contract verbs."
    return $true
}

Export-ModuleMember -Function Get-YurunaHostContractVerb, Assert-YurunaHostContractCoverage
