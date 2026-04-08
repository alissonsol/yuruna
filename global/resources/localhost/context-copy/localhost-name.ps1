<#PSScriptInfo
.VERSION 0.1
.GUID 42017293-a415-4623-9456-789012d5e6f0
.AUTHOR Alisson Sol
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

# Write the localhost name back for further processing
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