<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42ab6606-a979-4194-9acd-a8d1c653dace
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
    Each driver exports this common surface alongside its platform helpers.
    Assert-YurunaHostContractCoverage checks the actual module exports at load
    time. See https://yuruna.link/42e220c4-0004 for scope and naming rules.
#>

# --- REGION: Host driver contract
# Change every driver before adding a verb that shared callers will consume.
$script:YurunaHostContract = @(
    # --- REGION: VM lifecycle
    'New-VM', 'Start-VM', 'Stop-VM', 'Stop-VMForce', 'Remove-VM',
    'Rename-VM', 'Get-VMState',
    # --- REGION: VM inventory
    # Inventory errors must throw; they cannot authorize cleanup as an empty host.
    'Get-VMName',
    # --- REGION: Disk snapshots
    'Save-VMDiskSnapshot', 'Restore-VMDiskSnapshot', 'Test-VMDiskSnapshot',
    # --- REGION: VM console
    'Test-VMConsoleOpen', 'Restart-VMConsole',
    # --- REGION: Image
    'Get-Image', 'Get-ImagePath',
    # --- REGION: VM I/O
    'Send-Text', 'Send-Key', 'Send-Click',
    'Get-VMScreenshot', 'Get-VMConsoleHandle',
    # --- REGION: Discovery
    'Wait-VMIp', 'Get-VMIp', 'Get-VMMac',
    # --- REGION: Neighbor cache refresh
    # Each driver provides an active refresh alongside passive address discovery.
    'Update-GuestNeighborCache',
    # --- REGION: Networking
    'Get-ExternalNetwork', 'New-ExternalNetwork', 'Test-CacheVMOnExternalNetwork',
    # --- REGION: Port mapping
    'Add-PortMap', 'Remove-PortMap',
    'Get-BestHostIp', 'Get-GuestReachableHostIp',
    # --- REGION: Caching-proxy service
    'Test-CachingProxyServiceAvailable', 'Get-CachingProxyServiceVmIp',
    # --- REGION: Host config
    'Set-HostProxy', 'Clear-HostProxy', 'Remove-HostProxy',
    'Get-HostProxyBackupPath', 'Assert-Virtualization'
)

# --- REGION: Contract discovery
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

# --- REGION: Contract coverage
function Assert-YurunaHostContractCoverage {
    <#
    .SYNOPSIS
        Verifies that the supplied function list covers the canonical
        Yuruna.Host contract.
    .DESCRIPTION
        Each per-host Yuruna.Host.psm1 calls this once at module load,
        declaring the contract verbs it means to export and handing over
        its own module (-Module $ExecutionContext.SessionState.Module).
        The declaration alone is a second copy of the contract and can
        only validate the contract against itself; the module's export
        table is what callers actually see, so a verb that is declared
        here but never reached Export-ModuleMember counts as missing.
        Missing names are reported in a single Write-Warning naming
        every gap so the operator sees the full delta in one line.
        Returns $true when coverage is complete, $false otherwise --
        callers can fail loudly or continue based on policy.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExportedFunction,
        [System.Management.Automation.PSModuleInfo]$Module
    )
    $exported = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$ExportedFunction, [System.StringComparer]::OrdinalIgnoreCase)
    if ($Module) {
        # Export-ModuleMember has already published the driver's surface by
        # the time the driver calls this at the bottom of its module body,
        # so ExportedFunctions is populated and authoritative here. Keeping
        # only the names it agrees with is what makes the guard catch a verb
        # dropped from the export block instead of reporting a clean pass.
        $actual = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($Module.ExportedFunctions.Keys), [System.StringComparer]::OrdinalIgnoreCase)
        $exported.IntersectWith($actual)
    }
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

# --- REGION: Exports
Export-ModuleMember -Function Get-YurunaHostContractVerb, Assert-YurunaHostContractCoverage
