<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456761
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

<#
.SYNOPSIS
    Gracefully stops the Yuruna Stash Service VM. Does NOT delete the
    VM or its disk -- the spec (§2) explicitly excludes a
    Remove-StashServer cmdlet. A subsequent Start-StashServer rebuilds
    the VM idempotently (New-VM destroys the prior instance first).

    In-flight uploads are not drained (§3.2): a hard stop is
    acceptable. Partial files and status=pending metadata records
    remain on disk per the atomicity rules in §8.2.

.PARAMETER VMName   Name of the stash VM. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

$state = Get-VMState -VMName $VMName
if ($state -eq 'absent') {
    Write-Output "  VM '$VMName' not registered with $HostType -- nothing to stop."
    exit 0
}
if ($state -in @('stopped', 'shutoff')) {
    Write-Output "  VM '$VMName' is already stopped."
    exit 0
}

Write-Output "Stopping '$VMName' (current state: $state)..."
$ok = Stop-VM -VMName $VMName -Confirm:$false
if (-not $ok) {
    Write-Warning "Stop-VM returned `$false; escalating to Stop-VMForce..."
    $ok = Stop-VMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false
}
$finalState = Get-VMState -VMName $VMName
if ($finalState -in @('stopped', 'shutoff')) {
    Write-Output "Stopped."
} else {
    Write-Warning "VM '$VMName' final state: $finalState (expected stopped/shutoff). Inspect via the host's tooling."
    exit 1
}
exit 0
