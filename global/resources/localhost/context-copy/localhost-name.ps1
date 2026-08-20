<#PSScriptInfo
.VERSION 2026.08.20
.GUID 42531e7c-1bce-49c5-9010-bc4d48c1fe1a
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

$hostname = [System.Net.Dns]::GetHostName()
$addresses = [System.Net.Dns]::GetHostAddresses($hostname) |
    Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($_) }

if ($addresses -and $addresses.Count -gt 0) {
    $ip_address = $addresses[0].IPAddressToString
} else {
    $ip_address = '127.0.0.1'
}

# HACK: For localhost, using IP address to avoid issues in Docker resolving the hostname from inside the container
$hostname = $ip_address;
Write-Output "{ ""hostname"": ""$hostname"" }"
