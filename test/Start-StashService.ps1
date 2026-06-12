<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456760
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
    Brings up the Yuruna Stash Service VM (host.windows.hyper-v,
    host.ubuntu.kvm, host.macos.utm). See
    https://yuruna.link/stash-service for the full specification.

.PARAMETER VMName   Name for the stash VM. Default: yuruna-stash-service.
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
# Same module set as Start-CachingProxy: Test.HostContract (for Get-HostType /
# Initialize-YurunaHost), Test.VMUtility (host-agnostic helpers),
# Test.CachingProxy reuse not needed here (stash VM is independent of
# the cache).
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $RepoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.stash-service'
$newVm      = Join-Path $guestDir 'New-VM.ps1'
if (-not (Test-Path -LiteralPath $newVm)) {
    Write-Error "New-VM.ps1 not found for $HostType at $newVm"
    exit 1
}

# Delegate to the per-host New-VM. Each script already runs Get-Image
# auto-fetch when the base image is missing, tears down any prior VM,
# creates the new one, and (Hyper-V + KVM) starts it. UTM only builds
# the bundle -- registration + start lives below.
Write-Output ""
Write-Output "== Bringing up '$VMName' on $HostType =="
& pwsh -NoProfile -File $newVm -VMName $VMName
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Error "$newVm exited $rc -- aborting."
    exit $rc
}

# UTM-only: register the bundle and start the VM. Hyper-V and KVM
# already started the VM inside New-VM.ps1 (Hyper-V\Start-VM and
# virt-install --import respectively).
if ($HostType -eq 'host.macos.utm') {
    $UtmDir = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (-not (Test-Path $UtmDir)) {
        Write-Error "UTM bundle missing at $UtmDir after New-VM."
        exit 1
    }
    & utmctl status $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Registering bundle with UTM (open $UtmDir)..."
        & /usr/bin/open $UtmDir
        $waitDeadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $waitDeadline) {
            & utmctl status $VMName 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
        & utmctl status $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "UTM did not register '$VMName' within 60s. Open UTM manually, accept the bundle, then re-run."
            exit 1
        }
    }
    Write-Output "Starting '$VMName' via utmctl..."
    & utmctl start $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "utmctl start '$VMName' returned non-zero -- check UTM."
    }
}

Write-Output ""
Write-Output "== stash-service start: complete =="
Write-Output "  VM:       $VMName"
Write-Output "  Host:     $HostType"
Write-Output ""
Write-Output "Daemon install + launch is a later automation step (see"
Write-Output "https://yuruna.link/stash-service)."
Write-Output ""
Write-Output "Stop with: ./Stop-StashService.ps1"
exit 0
