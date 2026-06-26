<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42d0e1f2-a3b4-4c56-9789-0b1c2d3e4f53
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

# Yuruna.Host bootstrap: imports the matching host driver
# (host/<host>/modules/Yuruna.Host.psm1) into the runner's session so
# every test/ caller resolves the New-VM / Start-VM / Stop-VM / Get-VM /
# Remove-VM contract without a HostType branch. Also pulls in the
# Test.Host{Detection,Condition,Git} siblings with -Global so importing
# THIS module alone gives a caller the full Test.Host* surface area.

# Re-import the three sibling modules so a caller that only imports
# Test.HostBootstrap (or Test.HostContract -- the facade re-imports
# Bootstrap) still gets the full Test.Host* surface area. -Global so
# the names land in the caller's session; -Force so a stale cached
# copy is evicted; -DisableNameChecking because Get-* / Test-* /
# Assert-* / Set-* / Update-* / Install-* span many noun families.
foreach ($mod in @('Test.HostDetection.psm1','Test.HostCondition.psm1','Test.HostGit.psm1')) {
    $p = Join-Path $PSScriptRoot $mod
    if (Test-Path $p) {
        Import-Module $p -Global -Force -DisableNameChecking
    }
}

function Initialize-YurunaHost {
    <#
    .SYNOPSIS
    Imports the matching host driver (host/<host>/modules/Yuruna.Host.psm1)
    so test/ orchestration can call interface functions without HostType
    branches.
    .DESCRIPTION
    Determines the current host via Get-HostType, builds the absolute
    path to its Yuruna.Host.psm1, and imports it with -Global so every
    test/ caller (Invoke-TestRunner.ps1, Test-Sequence.ps1,
    sequence extensions, etc.) resolves the interface names directly.

    The driver's New-VM/Start-VM/Stop-VM/Get-VM/Remove-VM exports shadow
    Hyper-V's same-named cmdlets in the runner's session -- intentional;
    callers want the harness contract, and the driver's body uses
    module-qualified Hyper-V\... calls when it needs to talk to the
    underlying cmdlet.

    Idempotent: Import-Module -Force re-loads the driver if the file
    changes, otherwise no-ops.
    .PARAMETER RepoRoot
    Absolute path to the repo root (parent of host/ and test/). The
    runner already resolves this; pass it in to avoid re-deriving.
    .PARAMETER HostType
    Optional override for the host identifier; default is Get-HostType.
    Used by tests that simulate other hosts.
    .OUTPUTS
    [string] -- absolute path to the imported Yuruna.Host.psm1, or
    throws if the file is missing for the current host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$HostType
    )
    if (-not $HostType) { $HostType = Get-HostType }
    $hostFolderRel = Get-HostFolder -HostType $HostType
    $modulePath    = Join-Path $RepoRoot (Join-Path $hostFolderRel 'modules/Yuruna.Host.psm1')
    if (-not (Test-Path $modulePath)) {
        throw "Yuruna.Host.psm1 not found for $HostType (looked at $modulePath). Cannot dispatch host operations."
    }
    Import-Module $modulePath -Force -DisableNameChecking -Global
    # Test.VMUtility.psm1 holds host-agnostic test helpers (Wait-VMRunning,
    # ...) that build on the host driver's contract. Imported alongside
    # the driver so callers can rely on either set without a separate
    # bootstrap step.
    $vmCommonPath = Join-Path $RepoRoot 'test/modules/Test.VMUtility.psm1'
    if (Test-Path $vmCommonPath) {
        Import-Module $vmCommonPath -Force -DisableNameChecking -Global
    }
    Write-Verbose "Initialize-YurunaHost: imported $modulePath"
    return $modulePath
}

Export-ModuleMember -Function Initialize-YurunaHost