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
    Stops the OpenSSH server and uninstalls the Windows capability.

.DESCRIPTION
    Inverse of Start-SshServer.ps1. Stops the sshd service, then removes the
    OpenSSH.Server Windows capability. Safe to re-run: missing capability
    is treated as a no-op. The Windows firewall rule is left to DISM to
    clean up as part of the capability removal.

    Note: this is the HEAVY inverse. If you just want to temporarily disable
    the server, use the status-page button ("Disable SSH Server") — that
    only stops the sshd service without removing the capability, so
    re-enabling is instant rather than requiring another multi-minute
    install.

    Requires Administrator on Windows. No-op placeholder on host.macos.utm
    until Remote Login wiring is built.

.EXAMPLE
    pwsh test/Stop-SshServer.ps1
#>

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
    Write-Warning "SSH server uninstall is not implemented for host type '$HostType'."
    exit 0
}

$ok = Uninstall-SshServer -HostType $HostType
if (-not $ok) {
    Write-Error "SSH server uninstall failed. See warnings above."
    exit 1
}

Write-Output ""
Write-Output "SSH server: stopped and uninstalled."
