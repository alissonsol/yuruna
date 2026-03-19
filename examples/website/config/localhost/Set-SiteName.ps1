<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f60-7890-1a2b3c4d5e6f
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
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
    Maps a hostname alias to an IP address in the system hosts file.
.DESCRIPTION
    Adds or updates an entry in the hosts file so that ${env:websiteHost}
    resolves to ${env:_frontendIp}. Works on Windows, macOS, and Linux.
    The entry persists until manually removed or the hosts file is reset.
    Run once after each deployment (or reboot if the hosts file is reset).
.PARAMETER Hostname
    The hostname alias to register. Defaults to $env:websiteHost.
.PARAMETER IPAddress
    The IP address to map to. Defaults to $env:_frontendIp.
.EXAMPLE
    ./Set-SiteName.ps1
    ./Set-SiteName.ps1 -Hostname website.localhost -IPAddress 192.168.64.9
#>
param(
    [string]$Hostname  = $env:websiteHost,
    [string]$IPAddress = $env:_frontendIp
)

if (-not $Hostname)  { Write-Error "Hostname is required. Set env:websiteHost or pass -Hostname.";  exit 1 }
if (-not $IPAddress) { Write-Error "IPAddress is required. Set env:_frontendIp or pass -IPAddress."; exit 1 }

$hostsFile = if ($IsWindows) { "$env:SystemRoot\System32\drivers\etc\hosts" } else { '/etc/hosts' }

# Read current hosts file and strip any existing entry for this hostname
$lines   = Get-Content $hostsFile -ErrorAction Stop
$pattern = "^\s*[\d:.]+\s+$([regex]::Escape($Hostname))\s*$"
$updated = @($lines | Where-Object { $_ -notmatch $pattern }) + "$IPAddress  $Hostname"

if ($IsWindows) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Re-run this script from an elevated (Administrator) PowerShell prompt."
        exit 1
    }
    $updated | Set-Content $hostsFile -Encoding UTF8
} else {
    # macOS / Linux: pipe through sudo tee to write with elevated privileges
    $updated -join "`n" | sudo tee $hostsFile | Out-Null
}

Write-Information ">> Hosts file updated: $IPAddress  $Hostname  ($hostsFile)" -InformationAction Continue
