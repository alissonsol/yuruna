<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456751
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Installs (if needed) and starts the OpenSSH server on the current host.

.DESCRIPTION
    Host-aware driver around Test.SshServer's Install-SshServer function. On
    host.windows.hyper-v it adds the OpenSSH.Server Windows capability when
    absent, starts the sshd service, and sets it to Automatic. On
    host.macos.utm this is currently a placeholder (returns success without
    doing anything) until the sysadminctl/defaults Remote Login wiring is
    built.

    This script is run ONCE per host to make the machine reachable over SSH.
    Start-StatusServer.ps1 does NOT install the SSH server automatically.
    Runtime enable/disable is driven by hostSshServer.enabled in
    test.config.yml via the host-ssh-server extension; that path can
    toggle the sshd service ON/OFF but cannot install it.

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
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
Import-Module -Name $hostModPath -Force

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

[void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $TestRoot) -HostType $HostType)

if (-not (Test-SshServerSupported)) {
    Write-Warning "SSH server install is not implemented for host type '$HostType'."
    exit 0
}

$ok = Install-SshServer -Confirm:$false
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
