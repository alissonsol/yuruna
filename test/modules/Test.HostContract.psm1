<#PSScriptInfo
.VERSION 2026.07.14
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
# know the facade -- the runner, Test-Sequence.ps1, sequence
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

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Invoke-LibvirtGroupReExecIfNeeded, Initialize-YurunaHost, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Test-HostRequirement, Assert-HostConditionSet, Initialize-SudoCache, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Set-MacHostConditionSet, Set-WindowsHostConditionSet, Invoke-GitPull, Get-CurrentGitCommit, Get-FileLockingProcess, Update-ProjectClone, Test-GitRemoteAuthFailure, Write-GitAuthRefreshBanner