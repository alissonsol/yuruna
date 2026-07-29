<#PSScriptInfo
.VERSION 2026.07.29
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456701
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

# Thin facade for the Test.Host* family. The Test.Host* surface is
# split into four siblings along feature boundaries (detection,
# condition-set, git/project, host-driver bootstrap). Importing this
# file imports all four siblings with -Global so callers that only
# know the facade -- the runner, Invoke-TestSequence.ps1, sequence
# extensions -- get every export reachable. New code should import
# the matching sibling directly.
# Aligned with host/Yuruna.Host.Contract.psm1: the test-harness side
# of the host-contract boundary.

# Test.HostDetection carries the Test.VMUtility -Global self-heal at its
# own module scope, so importing it (first in the list below) re-lands
# Wait-VMRunning / Test-IpAddress / Format-IpUrlHost in the caller's
# session on every facade load. Keeping the self-heal only in the sibling
# also covers the callers that import Test.HostDetection directly without
# going through this facade.
$siblingModules = @(
    'Test.HostDetection.psm1',
    'Test.HostCondition.psm1',
    'Test.HostGit.psm1',
    'Test.HostBootstrap.psm1'
)
foreach ($mod in $siblingModules) {
    $p = Join-Path $PSScriptRoot $mod
    if (Test-Path $p) {
        Import-Module $p -Global -Force -DisableNameChecking
    }
}

function Stop-ConcurrentVM {
    <#
    .SYNOPSIS
        Stop every running VM the cycle is not allowed to share the host
        with. Returns $true when none remain running.
    .DESCRIPTION
        A leftover guest from a cycle that died before its teardown keeps
        running, and the next cycle cannot use the host until it is gone.
        Telling the operator to stop it by hand turns one failed cycle into
        an indefinite outage: the sweep that would clear it only runs once a
        cycle starts, and the cycle refuses to start while it is running.
        This breaks that loop by issuing the stop the operator would have
        typed.

        Stops, never deletes. A running VM this function does not recognize
        may be something the operator cares about; a stop is recoverable and
        a delete is not. Guests that are the framework's own to discard are
        removed by name prefix in the cycle sweep (Remove-TestVMFiles.ps1),
        where the prefix is what proves they are disposable.

        Host-neutral: enumeration and lifecycle both go through the host
        contract, so this behaves the same on UTM, Hyper-V and libvirt.
    .PARAMETER AlwaysAllow
        VM names that may keep running. The caching-proxy service is infrastructure
        the guests consume, not a competitor for the host.
    .PARAMETER ExceptVmName
        A VM to leave alone -- the dev loop where an operator re-runs a
        sequence against a guest they left up on purpose.
    .OUTPUTS
        [bool] $true when nothing disallowed is still running (including
        when the host could not be enumerated, which is reported but must
        not wedge every cycle on a flaky CLI); $false when a VM would not
        stop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [string[]]$AlwaysAllow = @('yuruna-caching-proxy-service'),
        [string]$ExceptVmName
    )
    if (-not (Get-Command Get-VMName -ErrorAction SilentlyContinue)) {
        Write-Verbose "Stop-ConcurrentVM: no host driver loaded; skipping."
        return $true
    }
    try {
        $all = @(Get-VMName)
    } catch {
        # "Could not ask the host" is not "nothing is running", but refusing
        # here would wedge every cycle on a host whose CLI is intermittently
        # unreachable. Report and let the per-host guard decide.
        Write-Warning "Stop-ConcurrentVM: could not enumerate VMs ($($_.Exception.Message)); proceeding without the single-VM guarantee."
        return $true
    }
    $stillRunning = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $all) {
        if ($AlwaysAllow -contains $name) { continue }
        if ($ExceptVmName -and $name -eq $ExceptVmName) { continue }
        if ((Get-VMState -VMName $name) -ne 'running') { continue }
        if (-not $PSCmdlet.ShouldProcess($name, 'Stop concurrent VM')) { continue }
        # Progress goes to the information stream, never the success stream:
        # this function's output IS its return value, so a Write-Output here
        # would make it return an array whose truthiness is always $true --
        # a caller testing `-not (Stop-ConcurrentVM)` would then never refuse.
        Write-Information -MessageData "  Stopping concurrent VM '$name' before the cycle starts." -InformationAction Continue
        try {
            [void](Stop-VMForce -VMName $name -Confirm:$false)
        } catch {
            Write-Warning "  Stop-VMForce failed for '$name': $($_.Exception.Message)"
        }
        if ((Get-VMState -VMName $name) -eq 'running') { [void]$stillRunning.Add($name) }
    }
    if ($stillRunning.Count -gt 0) {
        Write-Warning "Stop-ConcurrentVM: still running after a forced stop: $($stillRunning -join ', ')"
        return $false
    }
    return $true
}

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Invoke-LibvirtGroupReExecIfNeeded, Initialize-YurunaHost, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Test-HostRequirement, Assert-HostConditionSet, Initialize-SudoCache, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Set-MacHostConditionSet, Set-WindowsHostConditionSet, Invoke-GitPull, Get-CurrentGitCommit, Get-FileLockingProcess, Update-ProjectClone, Test-GitRemoteAuthFailure, Write-GitAuthRefreshBanner, Stop-ConcurrentVM