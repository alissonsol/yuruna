<#PSScriptInfo
.VERSION 2026.05.29
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

# Thin facade for the Test.Host* family. Test.Host.psm1 used to hold
# 25 functions in 2,441 lines; split into four sibling modules along
# feature boundaries (detection, condition-set, git/project, host-
# driver bootstrap). Importing this file imports
# all four siblings with -Global so every existing caller -- the
# runner, Test-Sequence.ps1, sequence extensions -- keeps working
# unchanged. New code should import the matching sibling directly.

# Module-level self-healing: re-import Test.VMUtility.psm1 with -Global
# every time Test.Host is loaded. The runner's cycle re-import block
# reloads Test.Host every cycle; doing the -Global import here keeps
# Wait-VMRunning / Test-IpAddress / Format-IpUrlHost (and the other
# cross-host helpers) in the runner's session even when something
# mid-cycle has wiped the global module table -- e.g. a sequence step
# calling `Get-Module | Remove-Module`, or a transitive Import-Module
# without -Global. Without this, a long-running macOS in-process runner
# could lose Wait-VMRunning at an unrelated moment and crash at the
# next New-VM.Resource step. -ErrorAction SilentlyContinue: a missing sibling
# is non-fatal here; Initialize-YurunaHost still fails loudly later if
# truly broken.
$vmCommonPath = Join-Path $PSScriptRoot 'Test.VMUtility.psm1'
if (Test-Path $vmCommonPath) {
    Import-Module $vmCommonPath -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
}

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

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Invoke-LibvirtGroupReExecIfNeeded, Initialize-YurunaHost, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Test-HostRequirement, Assert-HostConditionSet, Initialize-SudoCache, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Set-MacHostConditionSet, Set-WindowsHostConditionSet, Invoke-GitPull, Get-CurrentGitCommit, Get-FileLockingProcess, Update-ProjectClone