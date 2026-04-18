<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456751
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
    Installs (if needed) and starts the OpenSSH server on the current host.

.DESCRIPTION
    Host-aware driver around Test.SshServer's Install-SshServer function. On
    host.windows.hyper-v it adds the OpenSSH.Server Windows capability when
    absent, starts the sshd service, and sets it to Automatic. On
    host.macos.utm this is currently a placeholder (returns success without
    doing anything) until the sysadminctl/defaults Remote Login wiring is
    built.

    This script is run ONCE per host to make the machine reachable over SSH.
    Start-StatusServer.ps1 does NOT install the SSH server automatically —
    it only reports whether the server is available. The status-page button
    toggles the sshd service ON/OFF at runtime but cannot install it.

    Requires Administrator on Windows.

.EXAMPLE
    # One-time install + start:
    pwsh test/Start-SshServer.ps1

.EXAMPLE
    # After install, from an Ubuntu VM or peer host:
    scp ./file.txt user@<host-ip>:C:/Users/Public/
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
    Write-Warning "SSH server install is not implemented for host type '$HostType'."
    exit 0
}

$ok = Install-SshServer -HostType $HostType
if (-not $ok) {
    Write-Error "SSH server install failed. See warnings above."
    exit 1
}

Write-Output ""
Write-Output "SSH server: installed and enabled."
$machineName = (hostname).Trim()
$ip = try {
    ([System.Net.Dns]::GetHostAddresses($machineName) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        Select-Object -First 1).IPAddressToString
} catch { $null }
if ($ip) {
    Write-Output "  Connect via:  ssh $env:USERNAME@$ip"
    Write-Output "  Copy files:   scp ./file.txt $env:USERNAME@${ip}:C:/Users/Public/"
} else {
    Write-Output "  Connect via:  ssh $env:USERNAME@$machineName"
}
