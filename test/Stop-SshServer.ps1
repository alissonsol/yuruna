<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456752
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Stops the OpenSSH server. By default leaves the Windows capability
    installed so a later Start-SshServer.ps1 is fast; pass -Uninstall to
    also remove the capability.

.DESCRIPTION
    Default behavior (no switch) — calls Disable-SshServer: stops the sshd
    service, sets its startup to Manual so it won't come back on boot, and
    removes the Yuruna firewall rule. Leaves the OpenSSH.Server Windows
    capability installed, so the next Start-SshServer.ps1 only has to start
    the service (seconds), not re-run Add-WindowsCapability (multiple
    minutes).

    -Uninstall — calls Uninstall-SshServer: the above plus Remove-Windows-
    Capability. Use this when you want the machine back to the baseline
    state (no OpenSSH installed at all). Typically only needed for
    cleanup before imaging or to reset a broken install.

    Safe to re-run in both modes: missing service / missing capability /
    missing firewall rule are all treated as no-ops.

    Requires Administrator on Windows. No-op placeholder on host.macos.utm
    until Remote Login wiring is built.

.PARAMETER Uninstall
    Also remove the OpenSSH.Server Windows capability after stopping the
    service. Slower: next Start-SshServer.ps1 will need to reinstall.

.EXAMPLE
    # Default — stop the service, keep capability installed (fast re-enable):
    pwsh test/Stop-SshServer.ps1

.EXAMPLE
    # Full teardown — stop AND remove the capability:
    pwsh test/Stop-SshServer.ps1 -Uninstall
#>

param(
    [switch]$Uninstall
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

$ErrorActionPreference = "Stop"
$TestRoot   = $PSScriptRoot
$ModulesDir = Join-Path $TestRoot "modules"

$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
$sshModPath  = Join-Path $ModulesDir "Test.SshServer.psm1"
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
if (-not (Test-Path $sshModPath))  { Write-Error "Module not found: $sshModPath";  exit 1 }
Import-Module -Name $hostModPath -Force
Import-Module -Name $sshModPath  -Force

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

if (-not (Test-SshServerSupported -HostType $HostType)) {
    Write-Warning "SSH server stop is not implemented for host type '$HostType'."
    exit 0
}

if ($Uninstall) {
    $ok = Uninstall-SshServer -HostType $HostType
    if (-not $ok) {
        Write-Error "SSH server uninstall failed. See warnings above."
        exit 1
    }
    Write-Output ""
    Write-Output "SSH server: stopped and capability removed."
} else {
    $ok = Disable-SshServer -HostType $HostType
    if (-not $ok) {
        Write-Error "SSH server disable failed. See warnings above."
        exit 1
    }
    Write-Output ""
    Write-Output "SSH server: stopped (capability still installed; Start-SshServer.ps1 will be fast)."
    Write-Output "  For a full teardown: pwsh test/Stop-SshServer.ps1 -Uninstall"
}
