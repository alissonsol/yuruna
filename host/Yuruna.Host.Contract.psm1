<#PSScriptInfo
.VERSION 2026.08.19
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

    Rationale lives in docs/host-io.md and docs/test-harness.md;
    this file is the executable source of truth.

    Naming policy (by design):
        The generic verbs -- New-VM, Start-VM, Stop-VM, Remove-VM --
        deliberately collide with the Hyper-V module's cmdlet names:
        Hyper-V is one of three virtualization backends Yuruna supports
        (UTM, libvirt/KVM, Hyper-V), and a contract named for any one of
        them would mis-frame the abstraction. The per-host driver modules
        live under host/<host>/modules/ and are imported into the runner's
        session with -Global only when that host is selected, so the
        collision is scoped to the runner runspace -- the drivers are NOT
        on PSModulePath and won't shadow Hyper-V cmdlets in other shells.
        Callers that need the Hyper-V cmdlet inside a Yuruna sequence use
        module-qualified `Hyper-V\Start-VM`; the unqualified `Start-VM`
        always resolves to the active host's driver contract.
#>

# Verb names a Yuruna host driver is expected to export. Adding a verb
# here is a contract-widening event: every driver must implement it
# before the new verb is consumed by the orchestrator. Removing one is
# a deprecation event: confirm no caller references it before pulling.
$script:YurunaHostContract = @(
    # VM lifecycle
    'New-VM', 'Start-VM', 'Stop-VM', 'Stop-VMForce', 'Remove-VM',
    'Rename-VM', 'Get-VMState',
    # VM inventory. Get-VMName lets a caller clean up by name prefix without
    # branching on hypervisor: enumeration is the only host-specific part of
    # a prefix sweep, so exposing it here keeps every sweep -- cycle-start,
    # teardown, project teardown -- on one code path. It MUST distinguish
    # "no VMs" from "could not ask the host": a driver that returns an empty
    # list when its CLI is unreachable would let a sweep report a clean host
    # and let the orphan-file pass delete bundles that are still registered.
    'Get-VMName',
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
    # Update-GuestNeighborCache: the ACTIVE half of address discovery.
    # Get-VMIp is a passive read on every host, and on a bridged network with
    # no in-band guest agent a passive read answers only while the host's
    # neighbour cache still holds the guest. Each driver owns how -- or
    # whether -- its platform refreshes that cache, but every driver must
    # answer the question, so a shared caller can ask without feature-testing
    # for a function that exists on one host only.
    'Update-GuestNeighborCache',
    # External / shared network
    'Get-ExternalNetwork', 'New-ExternalNetwork', 'Test-CacheVMOnExternalNetwork',
    # Host port mapping
    'Add-PortMap', 'Remove-PortMap',
    'Get-BestHostIp', 'Get-GuestReachableHostIp',
    # Caching-proxy service probes
    'Test-CachingProxyServiceAvailable', 'Get-CachingProxyServiceVmIp',
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

Export-ModuleMember -Function Get-YurunaHostContractVerb, Assert-YurunaHostContractCoverage
