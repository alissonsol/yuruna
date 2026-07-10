<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42028304-b526-4734-a567-89012e6f7081
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

Write-Output "{ ""ip_address"": ""$ip_address"" }"